object frmThreadInThreads: TfrmThreadInThreads
  Left = 0
  Top = 0
  Caption = 'Running threads from background threads'
  ClientHeight = 299
  ClientWidth = 635
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  DesignSize = (
    635
    299)
  TextHeight = 13
  object btnOTLFromTask: TButton
    Left = 16
    Top = 16
    Width = 161
    Height = 25
    Caption = 'OTL from a OTL task'
    TabOrder = 0
    OnClick = btnOTLFromTaskClick
  end
  object btnOTLFromThread: TButton
    Left = 16
    Top = 55
    Width = 161
    Height = 25
    Caption = 'OTL from a TThread'
    TabOrder = 1
    OnClick = btnOTLFromThreadClick
  end
  object btnOTLFromThreadDrain: TButton
    Left = 16
    Top = 94
    Width = 161
    Height = 25
    Caption = 'OTL from a TThread (drain)'
    TabOrder = 2
    OnClick = btnOTLFromThreadDrainClick
  end
  object lbLog: TListBox
    Left = 200
    Top = 16
    Width = 417
    Height = 265
    Anchors = [akLeft, akTop, akRight, akBottom]
    ItemHeight = 13
    TabOrder = 3
  end
end
