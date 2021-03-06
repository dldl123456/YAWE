{(*}
(*------------------------------------------------------------------------------
 Delphi Code formatter source code

The Original Code is Converter.pas, released April 2000.
The Initial Developer of the Original Code is Anthony Steele. 
Portions created by Anthony Steele are Copyright (C) 1999-2004 Anthony Steele.
All Rights Reserved.
Contributor(s): Anthony Steele.

The contents of this file are subject to the Mozilla Public License Version 1.1
(the "License"). you may not use this file except in compliance with the License.
You may obtain a copy of the License at http://www.mozilla.org/NPL/

Software distributed under the License is distributed on an "AS IS" basis,
WITHOUT WARRANTY OF ANY KIND, either express or implied.
See the License for the specific language governing rights and limitations
under the License.
------------------------------------------------------------------------------*)
{*)}

unit Converter;

{
  5 July 2004
  Rewrote as a simpler sting->string converter.
  For file or ide, there will be wrapper classes not subclasses.
  Wrappers will also support the interface IConvert
}

interface

uses
  { delphi } SysUtils,
  { local } ConvertTypes, ParseTreeNode,
  BuildTokenList,
  BuildParseTree, BaseVisitor;

type

  TConverter = class(TObject)
  private
    { the strings for the in and out code }
    fsInputCode, fsOutputCode: string;

    { classes to lex and parse the source }
    fcTokeniser: TBuildTokenList;
    fcBuildParseTree: TBuildParseTree;

    { used for testing - just run 1 process }
    fcSingleProcess: TTreeNodeVisitorType;

    { state }
    fiTokenCount: integer;
    fbConvertError: boolean;
    fOnStatusMessage: TStatusMessageProc;

    function GetOnStatusMessage: TStatusMessageProc;
    procedure SetOnStatusMessage(const Value: TStatusMessageProc);

    procedure SendExceptionMessage(const pe: Exception);

    { call this to report the current state of the proceedings }
    procedure SendStatusMessage(const psUnit, psMessage: string;
      const piY, piX: integer);

    function GetRoot: TParseTreeNode;

    { this does the reformatting. Virtual method so can be overriden for testing }
    procedure ApplyProcesses;
    procedure ApplySingleProcess;

  public
    constructor Create;
    destructor Destroy; override;

    procedure Convert;
    procedure ConvertPart(const piStartIndex, piEndIndex: integer);

    procedure Clear;

    procedure CollectOutput(const pcRoot: TParseTreeNode);

    property InputCode: string read fsInputCode write fsInputCode;
    property OutputCode: string read fsOutputCode write fsOutputCode;

    property TokenCount: integer Read fiTokenCount;
    property ConvertError: boolean Read fbConvertError;

    property Root: TParseTreeNode Read GetRoot;

    property OnStatusMessage: TStatusMessageProc read GetOnStatusMessage write SetOnStatusMessage;
    property SingleProcess: TTreeNodeVisitorType Read fcSingleProcess Write fcSingleProcess;
  end;

implementation

uses
  { JCL }
  JclImports,
  { local }
  SourceTokenList, SourceToken,
  AllProcesses, ParseError, PreProcessorParseTree,
  TreeWalker, VisitSetXY, VisitSetNesting;

function StrInsert(const psSub, psMain: string; const piPos: integer): string;
begin
  Result := StrLeft(psMain, piPos - 1) + psSub + StrRestOf(psMain, piPos);
end;

constructor TConverter.Create;
begin
  inherited;

  { owned objects }
  fcTokeniser := TBuildTokenList.Create;
  fcBuildParseTree := TBuildParseTree.Create;
  fcSingleProcess := nil;
end;

destructor TConverter.Destroy;
begin
  FreeAndNil(fcTokeniser);
  FreeAndNil(fcBuildParseTree);

  inherited;
end;


procedure TConverter.Clear;
begin
  fsInputCode := '';
  fsOutputCode := '';
  fcSingleProcess := nil;
end;

procedure TConverter.Convert;
var
  lcTokenList: TSourceTokenList;
begin
  fbConvertError := False;

  // turn text into tokens
  fcTokeniser.SourceCode := InputCode;
  lcTokenList := fcTokeniser.BuildTokenList;
  try   { finally free the list  }
    try { show exceptions }
      fiTokenCount := lcTokenList.Count;
      lcTokenList.SetXYPositions;

      // remove conditional compilation stuph
      //if FormatSettings.PreProcessor.Enabled then
      RemoveConditionalCompilation(lcTokenList);

      // make a parse tree from it
      fcBuildParseTree.TokenList := lcTokenList;
      fcBuildParseTree.BuildParseTree;

    except
      on E: Exception do
      begin
        fbConvertError := True;
        SendExceptionMessage(E);
        //if (GetRegSettings.ShowParseTreeOption = eShowOnError) then
        {$IFDEF SHOW_PARSE_TREE_ON_ERROR}
          ShowParseTree;
        {$ENDIF}
        lcTokenList.Clear;
        // Send the exception upper
        Raise;
      end;
    end;
    (*
    if fbConvertError then
    begin
      { if there was a parse error, the rest of the unit was not parsed
       there may still be tokens in the list
       Free them or face a small but annoying memory leak. }
      lcTokenList.Clear;
    end; *)

    // should not be any tokens left
    //Assert(lcTokenList.Count = 0, 'Surplus tokens');

  finally
    lcTokenList.Free;
  end;

  try
    if not fbConvertError then
    begin
     // if (GetRegSettings.ShowParseTreeOption = eShowAlways) then
     {$IFDEF SHOW_PARSE_TREE}
      ShowParseTree;
     {$ENDIF}

      // do the processes
      if Assigned(fcSingleProcess) then
        ApplySingleProcess
      else
        ApplyProcesses;

      // assemble the output string
      fsOutputCode := '';
      //CollectOutput(fcBuildParseTree.Root);
    end;

    fcBuildParseTree.Clear;

  except
    on E: Exception do
    begin
      fbConvertError := True;
      SendExceptionMessage(E);
      // Send the exception upper
      Raise;
    end;
  end;
end;

{ this is what alters the code (in parse tree form) from source to output }
procedure TConverter.ApplyProcesses;
var
  lcProcess: TAllProcesses;
begin
  lcProcess := TAllProcesses.Create;
  try
    lcProcess.OnMessage := SendStatusMessage;
    lcProcess.Execute(fcBuildParseTree.Root);
  finally
    lcProcess.Free;
  end;
end;

procedure TConverter.ApplySingleProcess;
var
  lcProcess: TBaseTreeNodeVisitor;
  lcTreeWalker: TTreeWalker;
begin
  lcTreeWalker := TTreeWalker.Create;
  try

    // apply a visit setXY first
    lcProcess := TVisitSetXY.Create;
    try
      lcTreeWalker.Visit(GetRoot, lcProcess);
    finally
      lcProcess.Free;
    end;

    // and set up nesting levels
    lcProcess := TVisitSetNestings.Create;
    try
      lcTreeWalker.Visit(GetRoot, lcProcess);
    finally
      lcProcess.Free;
    end;

    // then apply the process
    lcProcess := SingleProcess.Create;
    try
      lcTreeWalker.Visit(GetRoot, lcProcess);
    finally
      lcProcess.Free;
    end;

  finally
    lcTreeWalker.Free;
  end;
end;


function TConverter.GetRoot: TParseTreeNode;
begin
  Result := fcBuildParseTree.Root;
end;

procedure TConverter.CollectOutput(const pcRoot: TParseTreeNode);
var
  liLoop: integer;
begin
  Assert(pcRoot <> nil);

  // is it a leaf with source?
  if (pcRoot is TSourceToken) then
  begin
    fsOutputCode := fsOutputCode + TSourceToken(pcRoot).SourceCode;
  end
  else
  begin
    // recurse, write out all child nodes
    for liLoop := 0 to pcRoot.ChildNodeCount - 1 do
    begin
      CollectOutput(pcRoot.ChildNodes[liLoop])
    end;
  end;
end;

function TConverter.GetOnStatusMessage: TStatusMessageProc;
begin
  Result := fOnStatusMessage;
end;

procedure TConverter.SetOnStatusMessage(const Value: TStatusMessageProc);
begin
  fOnStatusMessage := Value;
end;

procedure TConverter.SendExceptionMessage(const pe: Exception);
var
  lsMessage: string;
  liX, liY: integer;
  leParseError: TEParseError;
begin
  lsMessage := 'Exception ' + pe.ClassName +
        '  ' + pe.Message;

  if pe is TEParseError then
  begin
    leParseError := TEParseError(pe);
    lsMessage := lsMessage + AnsiLineBreak + 'Near ' + leParseError.TokenMessage;
    liX := leParseError.XPosition;
    liY := leParseError.YPosition;
  end
  else
  begin
    liX := -1;
    liY := -1;
  end;

  SendStatusMessage('', lsMessage, liY, liX);
end;

procedure TConverter.SendStatusMessage(const psUnit, psMessage: string;
  const piY, piX: integer);
begin
  if Assigned(fOnStatusMessage) then
    fOnStatusMessage(psUnit, psMessage, piY, piX);
end;

procedure TConverter.ConvertPart(const piStartIndex, piEndIndex: integer);
const
  FORMAT_START = '{<JCF_!*$>}';
  FORMAT_END = '{</JCF_!*$>}';
var
  liRealInputStart, liRealInputEnd: integer;
  liOutputStart, liOutputEnd: integer;
  lsNewOutput: string;
begin
  Assert(piStartIndex >= 0);
  Assert(piEndIndex >= piStartIndex);
  Assert(piEndIndex <= Length(InputCode));

  { round to nearest end of line }
  liRealInputStart := piStartIndex;
  liRealInputEnd := piEndIndex;

  { get to the start of the line }
  while (liRealInputStart > 1) and (not CharIsReturn(InputCode[liRealInputStart -1 ])) do
    dec(liRealInputStart);

  { get to the start of the next line }
  while (liRealInputEnd < Length(InputCode)) and (not CharIsReturn(InputCode[liRealInputEnd])) do
    inc(liRealInputEnd);
  while (liRealInputEnd < Length(InputCode)) and (CharIsReturn(InputCode[liRealInputEnd])) do
    inc(liRealInputEnd);

  { put markers into the input }
  fsInputCode := StrInsert(FORMAT_END, fsInputCode, liRealInputEnd);
  fsInputCode := StrInsert(FORMAT_START, fsInputCode, liRealInputStart);

  Convert;

  { locate the markers in the output,
    and replace before and after }
  liOutputStart := Pos(FORMAT_START, fsOutputCode) + Length(FORMAT_START);
  liOutputEnd := Pos(FORMAT_END, fsOutputCode);


  { splice }
  lsNewOutput := StrLeft(fsInputCode, liRealInputStart - 1);
  lsNewOutput := lsNewOutput + Copy(fsOutputCode, liOutputStart, (liOutputEnd - liOutputStart));
  lsNewOutput := lsNewOutput + StrRestOf(fsInputCode, liRealInputEnd + Length(FORMAT_START) + Length(FORMAT_END));

  fsOutputCode := lsNewOutput;
end;

end.
