{***************************************************************************}
{                                                                           }
{           DUnitX                                                          }
{                                                                           }
{           Copyright (C) 2015 Vincent Parrett & Contributors               }
{                                                                           }
{           vincent@finalbuilder.com                                        }
{           http://www.finalbuilder.com                                     }
{                                                                           }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}
{ Mobile GUI Contribution by Embarcadero                                    }
{***************************************************************************}

unit DUNitX.Loggers.MobileGUI;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, DUnitX.TestFramework,
  DUnitX.Extensibility, FMX.Controls.Presentation, FMX.StdCtrls, FMX.ListView.Types, FMX.ListView,
  FMX.ListView.Appearances, FMX.TabControl, System.Generics.Collections, FMX.ScrollBox, FMX.Memo,
  FMX.ListView.Adapters.Base, FMX.Memo.Types, Androidapi.Log;

type
  TMobileGUITestRunner = class(TForm, ITestLogger)
    Panel1: TPanel;
    TestsListView: TListView;
    ToolBar1: TToolBar;
    TabControl1: TTabControl;
    TestsTab: TTabItem;
    ResultsTab: TTabItem;
    Panel2: TPanel;
    RunTestsButton: TButton;
    Panel3: TPanel;
    FailList: TListView;
    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    Label4: TLabel;
    RunsLabel: TLabel;
    FailLabel: TLabel;
    SuccessLabel: TLabel;
    LeakedLabel: TLabel;
    FailedTestMessage: TMemo;
    Splitter1: TSplitter;
    TestProgress: TProgressBar;
    ProgressLabel: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure TestsListViewItemClick(const Sender: TObject;
      const AItem: TListViewItem);
    procedure FormDestroy(Sender: TObject);
    procedure RunTestsButtonClick(Sender: TObject);
    procedure FailListItemClick(const Sender: TObject;
      const AItem: TListViewItem);
  private
    FTestRunner: ITestRunner;
    FFixtureList: ITestFixtureList;
    FChecked: TList<Integer>;
    FLastResults: IRunResults;
    FFailedTests: TDictionary<String, ITestResult>;
    FAutoRunFired: boolean;
    procedure EnableAllTests(const AList: ITestFixtureList);
    procedure AutoRun;
  protected
    procedure OnTestingStarts(const threadId: TThreadID; testCount, testActiveCount: Cardinal);
    procedure OnStartTestFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
    procedure OnSetupFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
    procedure OnEndSetupFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
    procedure OnBeginTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnSetupTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnEndSetupTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnExecuteTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnTestSuccess(const threadId: TThreadID; const Test: ITestResult);
    procedure OnTestError(const threadId: TThreadID; const Error: ITestError);
    procedure OnTestFailure(const threadId: TThreadID; const Failure: ITestError);
    procedure OnTestIgnored(const threadId: TThreadID; const AIgnored: ITestResult);
    procedure OnTestMemoryLeak(const threadId: TThreadID; const Test: ITestResult);
    procedure OnLog(const logType: TLogLevel; const msg: string);
    procedure OnTeardownTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnEndTeardownTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnEndTest(const threadId: TThreadID; const Test: ITestResult);
    procedure OnTearDownFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
    procedure OnEndTearDownFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
    procedure OnEndTestFixture(const threadId: TThreadID; const results: IFixtureResult);
    procedure OnTestingEnds(const RunResults: IRunResults);
  public
    { Public declarations }
  end;

var
  MobileGUITestRunner: TMobileGUITestRunner;

implementation

{$R *.fmx}

uses
  DUnitX.Loggers.XML.NUnit, DUnitX.ResStrs;

{ TMobileGUITestRunner }

procedure DLog(const msg: string);
var utf8: RawByteString;
begin
  utf8 := UTF8Encode('OTL_DIAG: ' + msg);
  __android_log_write(ANDROID_LOG_INFO, MarshaledAString(RawByteString('OTL_DIAG')), MarshaledAString(utf8));
end;

procedure TMobileGUITestRunner.FailListItemClick(const Sender: TObject;
  const AItem: TListViewItem);
var
  TestResult: ITestResult;
begin
  testResult := FFailedTests[AItem.Detail];
  FailedTestMessage.Text := TestResult.Message;
end;

procedure TMobileGUITestRunner.FormCreate(Sender: TObject);
{$IFDEF CI}
var
  NUnitLogger: ITestLogger;
{$ENDIF}
begin
  DLog('FormCreate begin');
  FFailedTests := TDictionary<String, ITestResult>.Create;
  FChecked := TList<Integer>.Create;
  FTestRunner := TDUnitX.CreateRunner;
  FTestRunner.UseRTTI := True;
  FTestRunner.AddLogger(Self);
  DLog('FormCreate: runner created');
{$IFDEF CI}
  NUnitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
  FTestRunner.AddLogger(NUnitLogger);
{$ENDIF}
  RunsLabel.Text := '';
  FailLabel.Text := '';
  SuccessLabel.Text := '';
  LeakedLabel.Text := '';
  ProgressLabel.Text := '';
end;

procedure TMobileGUITestRunner.FormDestroy(Sender: TObject);
begin
  FFailedTests.Free;
  FChecked.Free;
end;

procedure TMobileGUITestRunner.FormShow(Sender: TObject);

  procedure BuildTree(const AFixtureList: ITestFixtureList);
  var
    LFixture : ITestFixture;
    LItem: TListViewItem;
    test : ITest;
  begin
    for LFixture in AFixtureList do
    begin
      if LFixture.HasTests then
      begin
        LItem := TestsListView.Items.Add;
        LItem.Text := LFixture.FullName;
        LItem.Tag := -1;
      end;

      if LFixture.HasChildFixtures then
        BuildTree(LFixture.Children);

      for test in LFixture.Tests do
      begin
        LItem := TestsListView.Items.Add;
        LItem.Text := LFixture.Name + '.' + test.Name;
        LItem.Text := LItem.Text.PadLeft(LItem.Text.Length + 2, ' ');
      end;
    end;
  end;

var
  lf: ITestFixture;
  nf: integer;
begin
  DLog('FormShow begin');
  try
    FFixtureList := FTestRunner.BuildFixtures as ITestFixtureList;
  except
    on E: Exception do begin
      DLog('FormShow: BuildFixtures RAISED ' + E.ClassName + ': ' + E.Message);
      raise;
    end;
  end;
  nf := 0;
  for lf in FFixtureList do Inc(nf);
  DLog('FormShow: top-level fixtures = ' + IntToStr(nf));
  BuildTree(FFixtureList);
  DLog('FormShow: ListView items = ' + IntToStr(TestsListView.Items.Count));
  if not FAutoRunFired then begin
    FAutoRunFired := True;
    TThread.ForceQueue(nil,
      procedure
      begin
        AutoRun;
      end);
  end;
end;

procedure TMobileGUITestRunner.EnableAllTests(const AList: ITestFixtureList);
var
  fixture: ITestFixture;
  test: ITest;
begin
  for fixture in AList do begin
    for test in fixture.Tests do
      test.Enabled := True;
    if fixture.HasChildFixtures then
      EnableAllTests(fixture.Children);
  end;
end;

procedure TMobileGUITestRunner.AutoRun;
var
  worker: TThread;
begin
  DLog('AutoRun begin (main thread)');
  EnableAllTests(FFixtureList);
  worker := TThread.CreateAnonymousThread(
    procedure
    var results: IRunResults;
    begin
      DLog('AutoRun: executing on worker thread...');
      try
        results := FTestRunner.Execute;
        DLog('AutoRun: TestCount=' + IntToStr(results.TestCount) +
             ' Passed='  + IntToStr(results.PassCount) +
             ' Failed='  + IntToStr(results.FailureCount) +
             ' Errors='  + IntToStr(results.ErrorCount) +
             ' Leaks='   + IntToStr(results.MemoryLeakCount) +
             ' Ignored=' + IntToStr(results.IgnoredCount));
      except
        on E: Exception do begin
          DLog('AutoRun worker RAISED ' + E.ClassName + ': ' + E.Message);
          exit;
        end;
      end;
      TThread.Queue(nil,
        procedure
        begin
          FLastResults := results;
          RunsLabel.Text    := IntToStr(results.TestCount);
          FailLabel.Text    := IntToStr(results.FailureCount);
          SuccessLabel.Text := IntToStr(results.PassCount);
          LeakedLabel.Text  := IntToStr(results.MemoryLeakCount);
          ProgressLabel.Text := STestRunComplete;
          TestProgress.Value := 100;
          DLog('AutoRun: UI updated, done');
        end);
    end);
  worker.FreeOnTerminate := True;
  worker.Start;
end;

procedure TMobileGUITestRunner.OnBeginTest(const threadId: TThreadID;
  const Test: ITestInfo);
begin
  DLog('-> ' + Test.FullName);
end;

procedure TMobileGUITestRunner.OnEndSetupFixture(const threadId: TThreadID;
  const fixture: ITestFixtureInfo);
begin

end;

procedure TMobileGUITestRunner.OnEndSetupTest(const threadId: TThreadID;
  const Test: ITestInfo);
begin

end;

procedure TMobileGUITestRunner.OnEndTearDownFixture(const threadId: TThreadID;
  const fixture: ITestFixtureInfo);
begin

end;

procedure TMobileGUITestRunner.OnEndTeardownTest(const threadId: TThreadID;
  const Test: ITestInfo);
begin

end;

procedure TMobileGUITestRunner.OnEndTest(const threadId: TThreadID;
  const Test: ITestResult);
var
  capturedTest: ITestResult;
begin
  capturedTest := Test;
  TThread.Queue(nil,
    procedure
    var LItem: TListViewItem;
    begin
      if (capturedTest.ResultType = TTestResultType.Failure)
       or (capturedTest.ResultType = TTestResultType.Error)
       or (capturedTest.ResultType = TTestResultType.MemoryLeak) then
      begin
        FFailedTests.AddOrSetValue(capturedTest.Test.FullName, capturedTest);
        LItem := FailList.Items.Add;
        LItem.Text   := capturedTest.Test.Name;
        LItem.Detail := capturedTest.Test.FullName;
      end;
    end);
end;

procedure TMobileGUITestRunner.OnEndTestFixture(const threadId: TThreadID;
  const results: IFixtureResult);
begin

end;

procedure TMobileGUITestRunner.OnExecuteTest(const threadId: TThreadID;
  const Test: ITestInfo);
begin

end;

procedure TMobileGUITestRunner.OnLog(const logType: TLogLevel;
  const msg: string);
begin

end;

procedure TMobileGUITestRunner.OnSetupFixture(const threadId: TThreadID;
  const fixture: ITestFixtureInfo);
begin

end;

procedure TMobileGUITestRunner.OnSetupTest(const threadId: TThreadID;
  const Test: ITestInfo);
begin

end;

procedure TMobileGUITestRunner.OnStartTestFixture(const threadId: TThreadID;
  const fixture: ITestFixtureInfo);
begin

end;

procedure TMobileGUITestRunner.OnTearDownFixture(const threadId: TThreadID;
  const fixture: ITestFixtureInfo);
begin

end;

procedure TMobileGUITestRunner.OnTeardownTest(const threadId: TThreadID;
  const Test: ITestInfo);
begin

end;

procedure TMobileGUITestRunner.OnTestError(const threadId: TThreadID;
  const Error: ITestError);
begin
  DLog('ERROR ' + Error.Test.FullName + ': ' + Error.Message);
end;

procedure TMobileGUITestRunner.OnTestFailure(const threadId: TThreadID;
  const Failure: ITestError);
begin
  DLog('FAIL ' + Failure.Test.FullName + ': ' + Failure.Message);
end;

procedure TMobileGUITestRunner.OnTestIgnored(const threadId: TThreadID;
  const AIgnored: ITestResult);
begin
  DLog('IGNORED ' + AIgnored.Test.FullName);
end;

procedure TMobileGUITestRunner.OnTestingEnds(const RunResults: IRunResults);
begin

end;

procedure TMobileGUITestRunner.OnTestingStarts(const threadId: TThreadID; testCount,
  testActiveCount: Cardinal);
begin

end;

procedure TMobileGUITestRunner.OnTestMemoryLeak(const threadId: TThreadID;
  const Test: ITestResult);
begin

end;

procedure TMobileGUITestRunner.OnTestSuccess(const threadId: TThreadID;
  const Test: ITestResult);
begin

end;

procedure TMobileGUITestRunner.RunTestsButtonClick(Sender: TObject);
var
  LCurrentIndex: Integer;

  procedure BuildEnabledTestsList(const AFixtureList: ITestFixtureList);
  var
    LFixture : ITestFixture;
    test : ITest;
  begin
    for LFixture in AFixtureList do
    begin
      if LFixture.HasTests then
        Inc(LCurrentIndex);

      if LFixture.HasChildFixtures then
        BuildEnabledTestsList(LFixture.Children);

      for test in LFixture.Tests do
      begin
        test.Enabled := FChecked.Contains(LCurrentIndex);
        Inc(LCurrentIndex);
      end;
    end;
  end;

begin
  LCurrentIndex := 0;
  RunsLabel.Text := '';
  FailLabel.Text := '';
  SuccessLabel.Text := '';
  LeakedLabel.Text := '';
  FailList.Selected := nil;
  FailList.Items.Clear;
  FFailedTests.Clear;
  TestProgress.Value := 0;
  BuildEnabledTestsList(FFixtureList);
  FLastResults := FTestRunner.Execute;
  ProgressLabel.Text := STestRunComplete;
  TestProgress.Value := 100;
  RunsLabel.Text := IntToStr(FLastResults.TestCount);
  FailLabel.Text := IntToStr(FLastResults.FailureCount);
  SuccessLabel.Text := IntToStr(FLastResults.PassCount);
  LeakedLabel.Text := IntToStr(FLastResults.MemoryLeakCount);
end;

procedure TMobileGUITestRunner.TestsListViewItemClick(const Sender: TObject;
  const AItem: TListViewItem);
var
  LIndex: Integer;
  I: Integer;
begin
  if AItem.Objects.AccessoryObject.Visible then
  begin
    AItem.Objects.AccessoryObject.Visible := False;
    if AItem.Tag = -1 then
    begin
      LIndex := AItem.Index;
      if LIndex < TestsListView.Items.Count then
        Inc(LIndex);
      if TestsListView.Items[LIndex].Tag = 1 then
      begin
        TestsListView.Items[LIndex].Objects.AccessoryObject.Visible := False;
        Inc(LIndex);
      end;
      for I := LIndex to TestsListView.Items.Count - 1 do
      begin
        if TestsListView.Items[I].Tag = 1 then
          Break
        else
        begin
          TestsListView.Items[I].Objects.AccessoryObject.Visible := False;
          FChecked.Remove(TestsListView.Items[I].Index);
        end;
      end;
    end;
    FChecked.Remove(AItem.Index);
  end
  else
  begin
    AItem.Objects.AccessoryObject.Visible := True;
    if AItem.Tag = -1 then
    begin
      LIndex := AItem.Index;
      if LIndex < TestsListView.Items.Count then
        Inc(LIndex);
      if TestsListView.Items[LIndex].Tag = -1 then
      begin
        TestsListView.Items[LIndex].Objects.AccessoryObject.Visible := True;
        Inc(LIndex);
      end;
      for I := LIndex to TestsListView.Items.Count - 1 do
      begin
        if TestsListView.Items[I].Tag = -1 then
          Break
        else
        begin
          TestsListView.Items[I].Objects.AccessoryObject.Visible := True;
          FChecked.Add(TestsListView.Items[I].Index);
        end;
      end;
    end;
    FChecked.Add(AItem.Index)
  end;
end;

end.
