unit kSQLTriggerRewrite;

interface

function RewriteTriggersGeneric(const SQLText: string): string;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.RegularExpressions,
  kStrUtils;

function RewriteTriggersGeneric(const SQLText: string): string;
var
  RegTrigger, RegUpdate, RegTable, RegVars, RegSetFields, RegWhereVar: TRegEx;
  Match, FieldMatch, TableMatch, VarMatch, SetMatch, WhereMatch: TMatch;
  Vars, SetFields: TArray<string>;
  TableName, TriggerText, FixedSQL, FixedBlock, FieldListSet, FieldListJoin, PrimaryKey: string;
  i: Integer;
begin
  FixedSQL := SQLText;

  // Regex: Triggerblöcke mit IF UPDATE(...) OR UPDATE(...)
  RegTrigger := TRegEx.Create(
    'IF\s*\(\s*UPDATE\s*\(\s*[A-Z0-9_]+\s*\)\s*(?:OR\s+UPDATE\s*\(\s*[A-Z0-9_]+\s*\))*\s*\)\s*BEGIN(.*?)^\s*END\b',
    [roSingleLine, roIgnoreCase, roMultiLine]);

  for Match in RegTrigger.Matches(SQLText) do
  begin
    TriggerText := Match.Value;

    // Prüfen, ob Variablenverwendung vorliegt
    if not (TriggerText.Contains('FROM inserted') and TriggerText.Contains('@')) then
      Continue;

    // Prüfen, ob Restrict vorliegt
    if TriggerText.Contains('FROM inserted') and TriggerText.Contains('@NullRows') then
      Continue;

    // Nur Trigger mit Variablen (@...) behandeln
    RegVars := TRegEx.Create('(@[A-Z0-9_]+)', [roIgnoreCase]);
    if RegVars.Matches(TriggerText).Count < 1 then
      Continue;

    // Alle Variablen sammeln (einmalig, keine Duplikate)
    SetLength(Vars, 0);
    for VarMatch in RegVars.Matches(TriggerText) do
    begin
      if IndexText(VarMatch.Groups[1].Value, Vars) = -1 then
      begin
        SetLength(Vars, Length(Vars) + 1);
        Vars[High(Vars)] := VarMatch.Groups[1].Value;
      end;
    end;

    // Tabellenname aus UPDATE <Tabelle>
    RegTable := TRegEx.Create('UPDATE\s+([A-Z0-9_]+)', [roIgnoreCase]);
    TableMatch := RegTable.Match(TriggerText);
    if TableMatch.Success then
      TableName := TableMatch.Groups[1].Value
    else
      TableName := 'CHILDTABLE';

    // PrimaryKey aus der WHERE-Klausel extrahieren
    RegWhereVar := TRegEx.Create('WHERE\s+(.*)', [roSingleLine, roIgnoreCase]);
    WhereMatch := RegWhereVar.Match(TriggerText);
    if WhereMatch.Success then begin
      PrimaryKey := Trim(WhereMatch.Groups[1].Value); // gesamte WHERE-Klausel
      PrimaryKey := PrimaryKey.Replace('deleted.', 'i.');
      PrimaryKey := PrimaryKey.Replace('END', '');
    end else
      PrimaryKey := TableName + '_ID'; // Fallback

    // Feldnamen aus SET-Klausel extrahieren (z.B. SET CBASE_BEH_TYP = @BASE_BEH_TYP, CKAT_NO = @KAT_NO)
    SetLength(SetFields, 0);
    // Erst die gesamte SET-Klausel finden
    var SetClause: string;
    var RegSetClause := TRegEx.Create('SET\s+(.*?)\s+FROM', [roSingleLine, roIgnoreCase]);
    var SetClauseMatch := RegSetClause.Match(TriggerText);

    if SetClauseMatch.Success then
    begin
      SetClause := SetClauseMatch.Groups[1].Value;

      // Dann alle Feldnamen extrahieren (Feld = Wert Pattern)
      RegSetFields := TRegEx.Create('([A-Z0-9_]+)\s*=\s*[@A-Z0-9_]+', [roIgnoreCase]);
      for SetMatch in RegSetFields.Matches(SetClause) do
      begin
        if IndexText(SetMatch.Groups[1].Value, SetFields) = -1 then
        begin
          SetLength(SetFields, Length(SetFields) + 1);
          SetFields[High(SetFields)] := SetMatch.Groups[1].Value;
        end;
      end;
    end;

    if Length(SetFields) = 0 then
      Continue;

    // SET-Teil dynamisch für alle Variablen
    FieldListSet := '';
    for i := 0 to High(SetFields) do
    begin
      FieldListSet := InsertDelimiter(FieldListSet, Format('ch.%s = i.%s', [SetFields[i], Copy(Vars[i], 2, MaxInt)]), ', ');
    end;

    // JOIN-Teil dynamisch für alle Variablen
    FieldListJoin := '';
    for i := 0 to High(Vars) do
    begin
      if i = 0 then
        FieldListJoin := Format('        ON ch.%s = d.%s%s', [SetFields[i], Copy(Vars[i], 2, MaxInt), sLineBreak])
      else
        FieldListJoin := FieldListJoin + Format('       AND ch.%s = d.%s%s', [SetFields[i], Copy(Vars[i], 2, MaxInt), sLineBreak]);
    end;

    var UpdateClause: string;
    UpdateClause := 'IF (';
    for i := 0 to High(Vars) do
    begin
      if i > 0 then
        UpdateClause := UpdateClause + ' OR ';
      UpdateClause := UpdateClause + 'UPDATE(' + Copy(Vars[i], 2, MaxInt) + ')';
    end;
    UpdateClause := UpdateClause + ')';

    // Null-sicherer "Wert hat sich geändert" WHERE-Block für alle Vars-Felder
    var ChangeWhere := '';
    for i := 0 to High(Vars) do
    begin
      var FieldName := Copy(Vars[i], 2, MaxInt);  // Spaltenname ohne führendes Zeichen
      if i > 0 then
        ChangeWhere := ChangeWhere + ' OR ';

      ChangeWhere := ChangeWhere +
        '( (i.' + FieldName + ' <> d.' + FieldName + ')' +
        ' OR (i.' + FieldName + ' IS NULL AND d.' + FieldName + ' IS NOT NULL)' +
        ' OR (i.' + FieldName + ' IS NOT NULL AND d.' + FieldName + ' IS NULL) )';
    end;

    // Neuen Triggerblock erzeugen
    if not ContainsText(PrimaryKey, '_NO = ') then begin
      FixedBlock :=
        UpdateClause + sLineBreak +
        '    BEGIN' + sLineBreak +

            // Check, ob Feld wirklich verändert
        '      IF EXISTS (' + sLineBreak +
        '        SELECT 1' + sLineBreak +
        '        FROM inserted i' + sLineBreak +
        '        CROSS JOIN deleted d' + sLineBreak +   // bei Single-Row ok
        '        WHERE (' + ChangeWhere + ')' + sLineBreak +
        '      )' + sLineBreak +
        '      BEGIN ' + sLineBreak +
            // Nur 1 Datensatz pro Statement erlauben
        '        IF (SELECT COUNT(*) FROM inserted) <> 1 OR (SELECT COUNT(*) FROM deleted) <> 1 ' +
        '        BEGIN ' + sLineBreak +
        '           THROW 50001, ''Es darf nur 1 Satz pro Statement upgedatet werden: ' + Trim(ReplaceStr(PrimaryKey, sLineBreak, '')) + ''', 1; ' +
        '        END; ' + sLineBreak +

        '        UPDATE ch' + sLineBreak +
        '        SET ' +
        FieldListSet +
        Format('    FROM %s ch%s', [TableName, sLineBreak]) +
        '        INNER JOIN deleted d' + sLineBreak +
        FieldListJoin +
        '        CROSS JOIN inserted i' + sLineBreak +   //Achtung, geht nur so und kann bei mehreren gleichzeitigen Updates in Inserted nicht funktionieren!!!
        '      END' + sLineBreak +
        '    END';
    end else begin
      // Bei FK aus nur 1 Feld (kein OR in UpdateClause) i per Primary Key mit d verknüpfen, THROW ohne Tabellenname;
      // bei FK aus 2 Feldern (OR in UpdateClause) reicht CROSS JOIN, da bereits auf genau 1 Satz geprüft wird, THROW mit Tabellenname.
      var JoinInsertedClause: string;
      var ThrowDetail: string;
      if Length(Vars) <= 1 then begin
        JoinInsertedClause :=
          '  INNER JOIN inserted i' + sLineBreak +
          Format('    ON %s%s', [PrimaryKey, sLineBreak]);
        ThrowDetail := Trim(ReplaceStr(PrimaryKey, sLineBreak, ''));
      end else begin
        JoinInsertedClause := '  CROSS JOIN inserted i' + sLineBreak;
        ThrowDetail := TableName + ', ' + Trim(ReplaceStr(PrimaryKey, sLineBreak, ''));
      end;

      FixedBlock :=
        UpdateClause + sLineBreak +
        'BEGIN' + sLineBreak +

        '  IF (SELECT COUNT(*) FROM inserted) <> 1 OR (SELECT COUNT(*) FROM deleted) <> 1' + sLineBreak +
        '  BEGIN' + sLineBreak +
        '      THROW 50001, ''Es darf nur 1 Satz pro Statement upgedatet werden: ' + ThrowDetail + ''', 1;' + sLineBreak +
        '  END;' + sLineBreak +

        '  UPDATE ch' + sLineBreak +
        '  SET ' + FieldListSet + sLineBreak +
        Format('  FROM %s ch%s', [TableName, sLineBreak]) +
        '  INNER JOIN deleted d' + sLineBreak +
        FieldListJoin +
        JoinInsertedClause +
        'END';
    end;

    // Alten Block im SQL ersetzen
    FixedSQL := FixedSQL.Replace(TriggerText, FixedBlock);
  end;

  Result := FixedSQL;
end;


end.
