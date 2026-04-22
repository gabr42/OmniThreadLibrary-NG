unit twoFishDB;

interface

uses
  System.SysUtils, System.Classes, Data.DB,
  FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Error, FireDAC.UI.Intf,
  FireDAC.Phys.Intf, FireDAC.Stan.Def, FireDAC.Stan.Pool, FireDAC.Stan.Async,
  FireDAC.Phys, FireDAC.Phys.IB, FireDAC.Phys.IBDef,
  FireDAC.VCLUI.Wait, FireDAC.Stan.Param, FireDAC.DatS, FireDAC.DApt.Intf,
  FireDAC.DApt, FireDAC.Comp.UI, FireDAC.Comp.Client, FireDAC.Comp.DataSet;

type
  TdmTwoFishDB = class(TDataModule)
    FDConnection1       : TFDConnection;
    FDPhysIBDriverLink1 : TFDPhysIBDriverLink;
    FDGUIxWaitCursor1   : TFDGUIxWaitCursor;
    FDTable1            : TFDTable;
    FDTable1CATEGORY    : TStringField;
    FDTable1SPECIES_NAME: TStringField;
    FDTable1LENGTH__CM_ : TFloatField;
    FDTable1LENGTH_IN   : TFloatField;
    FDTable1COMMON_NAME : TStringField;
    FDTable1NOTES       : TMemoField;
    FDTable1GRAPHIC     : TBlobField;
  private
  public
  end;

var
  dmTwoFishDB: TdmTwoFishDB;

implementation

{%CLASSGROUP 'System.Classes.TPersistent'}

{$R *.dfm}

end.
