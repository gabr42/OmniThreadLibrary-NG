unit test_36_ParallelAggregate;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, Spin;

type
  TfrmParallelAggregateDemo = class(TForm)
    btnCountParallel: TButton;
    btnCountSequential: TButton;
    btnSumParallel: TButton;
    btnSumSequential: TButton;
    inpMaxPrime: TSpinEdit;
    inpMaxSummand: TSpinEdit;
    inpNumCPU: TSpinEdit;
    Label1: TLabel;
    Label3: TLabel;
    lblCountPrimes: TLabel;
    lbLog: TListBox;
    btnSumParallel2: TButton;
    btnCountParallel2: TButton;
    procedure btnCountParallel2Click(Sender: TObject);
    procedure btnCountParallelClick(Sender: TObject);
    procedure btnCountSequentialClick(Sender: TObject);
    procedure btnSumParallel2Click(Sender: TObject);
    procedure btnSumParallelClick(Sender: TObject);
    procedure btnSumSequentialClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
  private
    function  IsPrime(i: integer): boolean;
    procedure Log(const msg: string; const params: array of const);
  end;

var
  frmParallelAggregateDemo: TfrmParallelAggregateDemo;

implementation

uses
  System.Diagnostics,
  OtlCommon,
  OtlSync,
  OtlParallel;

{$R *.dfm}

procedure TfrmParallelAggregateDemo.btnCountParallel2Click(Sender: TObject);
var
  lockNum  : TOmniCS;
  numPrimes: integer;
  sw       : TStopwatch;
begin
  sw := TStopwatch.StartNew;
  numPrimes := 0;
  Parallel.ForEach(1, inpMaxPrime.Value)
    .NumTasks(inpNumCPU.Value)
    .Initialize(
      procedure (var taskState: TOmniValue)
      begin
        taskState.AsInteger := 0;
      end)
    .Finalize(
      procedure (const taskState: TOmniValue)
      begin
        lockNum.Acquire;
        try
          numPrimes := numPrimes + taskState.AsInteger;
        finally lockNum.Release; end;
      end)
    .Execute(
      procedure (const value: integer; var taskState: TOmniValue)
      begin
        if IsPrime(value) then
          taskState.AsInteger := taskState.AsInteger + 1;
      end
    );
  Log('%d primes from 1 to %d; calculation took %d ms', [numPrimes, inpMaxPrime.Value, sw.ElapsedMilliseconds]);
end;

procedure TfrmParallelAggregateDemo.btnCountParallelClick(Sender: TObject);
var
  numPrimes: integer;
  sw       : TStopwatch;
begin
  sw := TStopwatch.StartNew;
  numPrimes :=
    Parallel.ForEach(1, inpMaxPrime.Value)
    .NumTasks(inpNumCPU.Value)
    .Aggregate(0,
      procedure (var aggregate: TOmniValue; const value: TOmniValue)
      begin
        aggregate := aggregate.AsInt64 + value.AsInt64;
      end)
    .Execute(
      procedure (const value: integer; var result: TOmniValue)
      begin
        if IsPrime(value) then
          Result := 1;
      end
    );
  Log('%d primes from 1 to %d; calculation took %d ms', [numPrimes, inpMaxPrime.Value, sw.ElapsedMilliseconds]);
end;

procedure TfrmParallelAggregateDemo.btnCountSequentialClick(Sender: TObject);
var
  i        : integer;
  numPrimes: integer;
  sw       : TStopwatch;
begin
  sw := TStopwatch.StartNew;
  numPrimes := 0;
  for i := 1 to inpMaxPrime.Value do
    if IsPrime(i) then
      Inc(numPrimes);
  Log('%d primes from 1 to %d; calculation took %d ms', [numPrimes, inpMaxPrime.Value, sw.ElapsedMilliseconds]);
end;

procedure TfrmParallelAggregateDemo.btnSumParallel2Click(Sender: TObject);
var
  lockSum: TOmniCS;
  sw     : TStopwatch;
  sum    : int64;
begin
  sw := TStopwatch.StartNew;
  sum := 0;
  Parallel
    .ForEach(1, inpMaxSummand.Value)
    .NumTasks(inpNumCPU.Value)
    .Initialize(
      procedure (var taskState: TOmniValue)
      begin
        taskState := 0;
      end)
    .Finalize(
      procedure (const taskState: TOmniValue)
      begin
        lockSum.Acquire;
        try
          sum := sum + taskState.AsInt64;
        finally lockSum.Release; end;
      end
    )
    .Execute(
      procedure (const value: integer; var taskState: TOmniValue)
      begin
        taskState.AsInt64 := taskState.AsInt64 + value;
      end
    );
  Log('Sum(1..%d) = %d; calculation took %d ms', [inpMaxSummand.Value, sum, sw.ElapsedMilliseconds]);
end;

procedure TfrmParallelAggregateDemo.btnSumParallelClick(Sender: TObject);
var
  sw : TStopwatch;
  sum: int64;
begin
  sw := TStopwatch.StartNew;
  sum :=
    Parallel
    .ForEach(1, inpMaxSummand.Value)
    .NumTasks(inpNumCPU.Value)
    .AggregateSum
    .Execute(
      procedure (const value: integer; var result: TOmniValue)
      begin
        Result := value;
      end
    );
  Log('Sum(1..%d) = %d; calculation took %d ms', [inpMaxSummand.Value, sum, sw.ElapsedMilliseconds]);
end;

procedure TfrmParallelAggregateDemo.btnSumSequentialClick(Sender: TObject);
var
  i  : integer;
  sw : TStopwatch;
  sum: int64;
begin
  sw := TStopwatch.StartNew;
  sum := 0;
  for i := 1 to inpMaxSummand.Value do
    Inc(sum, i);
  Log('Sum(1..%d) = %d; calculation took %d ms', [inpMaxSummand.Value, sum, sw.ElapsedMilliseconds]);
end;

procedure TfrmParallelAggregateDemo.FormCreate(Sender: TObject);
begin
  inpNumCPU.MaxValue := 64;
  inpNumCPU.Value := Environment.Process.Affinity.Count;
end;

function TfrmParallelAggregateDemo.IsPrime(i: integer): boolean;
var
  j: integer;
begin
  Result := false;
  if i <= 1 then
    Exit;
  for j := 2 to Round(Sqrt(i)) do
    if (i mod j) = 0 then
      Exit;
  Result := true;
end;

procedure TfrmParallelAggregateDemo.Log(const msg: string; const params: array of const);
begin
  lbLog.ItemIndex := lbLog.Items.Add(Format(msg, params));
end;

end.
