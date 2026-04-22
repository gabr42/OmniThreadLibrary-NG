object dmTwoFishDB: TdmTwoFishDB
  Height = 226
  Width = 215
  object FDConnection1: TFDConnection
    Params.Strings = (
      'DriverID=IB'
      'Protocol=Local'
      'Database=C:\Users\Public\Documents\Embarcadero\Studio\37.0\Samples\Da' +
        'ta\dbdemos.gdb'
      'User_Name=sysdba'
      'Password=masterkey')
    LoginPrompt = False
    Left = 48
    Top = 64
  end
  object FDPhysIBDriverLink1: TFDPhysIBDriverLink
    Left = 112
    Top = 64
  end
  object FDGUIxWaitCursor1: TFDGUIxWaitCursor
    Provider = 'Forms'
    Left = 176
    Top = 64
  end
  object FDTable1: TFDTable
    IndexFieldNames = 'SPECIES_NO'
    ReadOnly = True
    Connection = FDConnection1
    UpdateOptions.UpdateTableName = 'BIOLIFE'
    TableName = 'BIOLIFE'
    Left = 48
    Top = 120
    object FDTable1CATEGORY: TStringField
      DisplayLabel = 'Category'
      FieldName = 'CATEGORY'
      Size = 15
    end
    object FDTable1SPECIES_NAME: TStringField
      DisplayLabel = 'Species Name'
      FieldName = 'SPECIES_NAME'
      Size = 40
    end
    object FDTable1LENGTH__CM_: TFloatField
      DisplayLabel = 'Length (cm)'
      FieldName = 'LENGTH__CM_'
    end
    object FDTable1LENGTH_IN: TFloatField
      DisplayLabel = 'Length_In'
      FieldName = 'LENGTH_IN'
      DisplayFormat = '0.00'
    end
    object FDTable1COMMON_NAME: TStringField
      DisplayLabel = 'Common Name'
      FieldName = 'COMMON_NAME'
      Size = 30
    end
    object FDTable1NOTES: TMemoField
      DisplayLabel = 'Notes'
      FieldName = 'NOTES'
      BlobType = ftMemo
    end
    object FDTable1GRAPHIC: TBlobField
      DisplayLabel = 'Graphic'
      FieldName = 'GRAPHIC'
    end
  end
end
