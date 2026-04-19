program OtlAndroidTests;

uses
  System.StartUpCopy,
  FMX.Forms
  , FMX.Types
  , System.SysUtils
  , Androidapi.Log
  , DUnitX.TestFramework
  , TestOtlBase in 'TestOtlBase.pas'
  , SmokeTest in 'SmokeTest.pas'
  , TestRegressions in 'TestRegressions.pas'
  , TestBlockingCollection1 in 'TestBlockingCollection1.pas'
  , TestOtlDataManager1 in 'TestOtlDataManager1.pas'
  , TestOmniInterfaceDictionary in 'TestOmniInterfaceDictionary.pas'
  , TestOmniValue in 'TestOmniValue.pas'
  , TestValue in 'TestValue.pas'
  , TestPlatform in 'TestPlatform.pas'
  , TestInterlocked in 'TestInterlocked.pas'
  , TestContainers in 'TestContainers.pas'
  , TestOtlComm in 'TestOtlComm.pas'
  , TestOtlSync1 in 'TestOtlSync1.pas'
  , TestOtlCommon1 in 'TestOtlCommon1.pas'
  , TestContainerObserver1 in 'TestContainerObserver1.pas'
  , TestSyncUtils1 in 'TestSyncUtils1.pas'
  , TestBackgroundObserver1 in 'TestBackgroundObserver1.pas'
  , TestChannel1 in 'TestChannel1.pas'
  , TestSelect1 in 'TestSelect1.pas'
  , TestMergeRace1 in 'TestMergeRace1.pas'
  , TestHooks1 in 'TestHooks1.pas'
  , TestTask in 'TestTask.pas'
  , TestOtlParallel in 'TestOtlParallel.pas'
  , TestUnobserved in 'TestUnobserved.pas'
  , DUNitX.Loggers.MobileGUI in 'DUNitX.Loggers.MobileGUI.pas' {MobileGUITestRunner};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TMobileGUITestRunner, MobileGUITestRunner);
  Application.Run;
end.
