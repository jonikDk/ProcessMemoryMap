﻿////////////////////////////////////////////////////////////////////////////////
//
//  ****************************************************************************
//  * Project   : ProcessMM
//  * Unit Name : uRegionProperties.pas
//  * Purpose   : Диалог для отображения данных по переданному адресу
//  * Author    : Александр (Rouse_) Багель
//  * Copyright : © Fangorn Wizards Lab 1998 - 2017, 2022.
//  * Version   : 1.3.19
//  * Home Page : http://rouse.drkb.ru
//  * Home Blog : http://alexander-bagel.blogspot.ru
//  ****************************************************************************
//  * Stable Release : http://rouse.drkb.ru/winapi.php#pmm2
//  * Latest Source  : https://github.com/AlexanderBagel/ProcessMemoryMap
//  ****************************************************************************
//

unit uRegionProperties;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ComCtrls, Winapi.PsAPI, Vcl.Menus,

  MemoryMap.Utils,
  MemoryMap.Core,
  MemoryMap.RegionData,
  MemoryMap.Threads,
  MemoryMap.NtDll,
  MemoryMap.Workset,

  RawScanner.Core,
  RawScanner.ModulesData,
  RawScanner.SymbolStorage,

  uDumpDisplayUtils;

type
  TDumpFunc = reference to function (Process: THandle; Address: Pointer): string;
  TdlgRegionProps = class(TForm)
    edProperties: TRichEdit;
    mnuPopup: TPopupMenu;
    mnuCopy: TMenuItem;
    N1: TMenuItem;
    mnuRefresh: TMenuItem;
    N2: TMenuItem;
    mnuShowAsDisassembly: TMenuItem;
    mnuGotoAddress: TMenuItem;
    N3: TMenuItem;
    mnuDasmMode: TMenuItem;
    mnuDasmMode86: TMenuItem;
    mnuDasmMode64: TMenuItem;
    mnuDasmModeAuto: TMenuItem;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure mnuCopyClick(Sender: TObject);
    procedure FormKeyPress(Sender: TObject; var Key: Char);
    procedure mnuRefreshClick(Sender: TObject);
    procedure mnuShowAsDisassemblyClick(Sender: TObject);
    procedure mnuGotoAddressClick(Sender: TObject);
    procedure mnuPopupPopup(Sender: TObject);
    procedure mnuDasmModeAutoClick(Sender: TObject);
  private
    ACloseAction: TCloseAction;
    Process: THandle;
    CurerntAddr: Pointer;
    SelectedAddr: ULONG_PTR;
    ShowAsDisassembly: Boolean;
    DAsmMode: TDasmMode;
    procedure Add(const Value: string); overload;
    procedure Add(AFunc: TDumpFunc; Process: THandle; Address: Pointer); overload;
    procedure StartQuery(Value: Pointer);
    procedure ShowInfoFromMBI(Process: THandle;
      MBI: TMemoryBasicInformation; Address: Pointer);
  public
    procedure ShowPropertyAtAddr(Value: Pointer; AsDisassembly: Boolean);
  end;

var
  dlgRegionProps: TdlgRegionProps;

implementation

uses
  uUtils,
  uSettings,
  uDisplayUtils;

const
  DefCaption = 'Process Memory Map - Region Properties [0x%x]';

{$R *.dfm}

{ TdlgRegionProps }

procedure TdlgRegionProps.Add(AFunc: TDumpFunc;
  Process: THandle; Address: Pointer);
var
  Value: string;
begin
  try
    Value := AFunc(Process, Address);
  except
    on E: EAbort do
      Value := Value + '...no more data';
    on E: Exception do
      Value := Value + sLineBreak + E.ClassName + ': ' + E.Message;
  end;
  edProperties.Lines.Add(Value);
end;

procedure TdlgRegionProps.Add(const Value: string);
begin
  edProperties.Lines.Add(Value);
end;

procedure TdlgRegionProps.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := ACloseAction;
end;

procedure TdlgRegionProps.FormKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #27 then Close;
end;

procedure TdlgRegionProps.mnuCopyClick(Sender: TObject);
begin
  edProperties.CopyToClipboard;
end;

procedure TdlgRegionProps.mnuGotoAddressClick(Sender: TObject);
begin
  if SelectedAddr <> 0 then
  begin
    dlgRegionProps := TdlgRegionProps.Create(Application);
    dlgRegionProps.ShowPropertyAtAddr(Pointer(SelectedAddr), ShowAsDisassembly);
  end;
end;

procedure TdlgRegionProps.mnuPopupPopup(Sender: TObject);
var
  HexAddr: Int64;
begin
  SelectedAddr := 0;
  if HexValueToInt64(edProperties.SelText, HexAddr) then
    SelectedAddr := ULONG_PTR(HexAddr);
  if SelectedAddr = 0 then
  begin
    var S := Trim(edProperties.SelText);
    var StartText := Pos('/', S);
    if StartText > 0 then
    begin
      S := Copy(S, StartText + 1, Length(S));
      if (S.Length > 0) and (S[1] = '/') then
        S[1] := ' ';
      S := Trim(S);
    end;
    SelectedAddr := MemoryMapCore.DebugMapData.GetAddrFromDescription(S);
  end;
  mnuGotoAddress.Enabled := SelectedAddr <> 0;
end;

procedure TdlgRegionProps.mnuRefreshClick(Sender: TObject);
var
  ThumbPos: Integer;
begin
  edProperties.Lines.BeginUpdate;
  try
    ThumbPos := SendMessage(edProperties.Handle, EM_GETFIRSTVISIBLELINE, 0, 0);
    edProperties.Lines.Clear;
    StartQuery(CurerntAddr);
    SendMessage(edProperties.Handle, EM_LINESCROLL, 0, ThumbPos);
  finally
    edProperties.Lines.EndUpdate;
  end;
end;

procedure TdlgRegionProps.mnuShowAsDisassemblyClick(Sender: TObject);
begin
  ShowAsDisassembly := mnuShowAsDisassembly.Checked;
  edProperties.Lines.BeginUpdate;
  try
    edProperties.Lines.Clear;
    StartQuery(CurerntAddr);
  finally
    edProperties.Lines.EndUpdate;;
  end;
end;

procedure TdlgRegionProps.ShowInfoFromMBI(Process: THandle;
  MBI: TMemoryBasicInformation; Address: Pointer);
var
  OwnerName: array [0..MAX_PATH - 1] of Char;
  Path, DescriptionAtAddr: string;
  Workset: TWorkset;
  Shared: Boolean;
  SharedCount: Byte;
  ExpData: TSymbolData;
  Module: TRawPEImage;
  Index: Integer;
  AddrVA: ULONG64;
begin
  Add('AllocationBase: ' + UInt64ToStr(ULONG_PTR(MBI.AllocationBase)));
  Add('RegionSize: ' + SizeToStr(MBI.RegionSize));
  Add('Type: ' + ExtractRegionTypeString(MBI));
  Add('Access: ' + ExtractAccessString(MBI.Protect));
  Add('Initail Access: ' + ExtractInitialAccessString(MBI.AllocationProtect));
  Workset := TWorkset.Create(Process);
  try
    Workset.GetPageSharedInfo(Pointer(ULONG_PTR(Address) and
     {$IFDEF WIN32}$FFFFF000{$ELSE}$FFFFFFFFFFFFF000{$ENDIF}), Shared, SharedCount);
  finally
    Workset.Free;
  end;
  Add('Shared: ' + BoolToStr(Shared, True));
  Add('Shared count: ' + IntToStr(SharedCount));
  if GetMappedFileName(Process, MBI.AllocationBase,
    @OwnerName[0], MAX_PATH) > 0 then
  begin
    Path := NormalizePath(string(OwnerName));
    Caption := Caption + ' "' + ExtractFileName(Path) + '"';
    Add('Mapped file: ' + Path);
    if CheckPEImage(Process, MBI.AllocationBase) then
      if RawScannerCore.Modules.GetModule(ULONG64(MBI.AllocationBase)) < 0 then
        Add(' -> No Executable PE Image!!!');

    DescriptionAtAddr :=
      MemoryMapCore.DebugMapData.GetDescriptionAtAddrWithOffset(ULONG_PTR(Address));
    if DescriptionAtAddr <> '' then
      Add('Function: ' + DescriptionAtAddr)
    else
    begin
      // вернет запись или sdtExport или sdtEntryPoint
      if SymbolStorage.GetExportAtAddr(ULONG_PTR(Address), stExport, ExpData) then
      begin
        Module := RawScannerCore.Modules.Items[ExpData.Binary.ModuleIndex];
        DescriptionAtAddr := 'Function: ' + Module.ImageName + '!';
        Index := ExpData.Binary.ListIndex;

        if ExpData.DataType = sdtEntryPoint then
        begin
          DescriptionAtAddr := DescriptionAtAddr +
            Module.EntryPointList.List[Index].EntryPointName;
          AddrVA := Module.EntryPointList.List[Index].AddrVA;
        end
        else  // sdtExport
        begin
          DescriptionAtAddr := DescriptionAtAddr +
            Module.ExportList.List[Index].ToString;
          AddrVA := Module.ExportList.List[Index].FuncAddrVA;
        end;

        if AddrVA <> ULONG_PTR(Address) then
          DescriptionAtAddr := DescriptionAtAddr + ' + 0x' +
            IntToHex(ULONG_PTR(Address) - AddrVA, 1);
        Add(DescriptionAtAddr);
      end;
    end;
  end;
end;

procedure TdlgRegionProps.ShowPropertyAtAddr(Value: Pointer; AsDisassembly: Boolean);
begin
  ShowAsDisassembly := AsDisassembly;
  mnuShowAsDisassembly.Checked := AsDisassembly;
  ACloseAction := caFree;
  StartQuery(Value);
  Show;
end;

procedure TdlgRegionProps.StartQuery(Value: Pointer);
const
  KUSER_SHARED_DATA_ADDR = Pointer($7FFE0000);

  function GetPageAddr: Pointer;
  begin
    Result := Pointer(NativeUInt(Value) and not $FFF);
  end;

  function CheckThreadData(AFlag: TThreadInfo; Use32AddrMode: Boolean): Boolean;
  begin
    case AFlag of
      tiTEB:
      begin
        {$IFDEF WIN32}
        Add(DumpThread32, Process, Value);
        {$ELSE}
        if Use32AddrMode then
          Add(DumpThread32, Process, Value)
        else
          Add(DumpThread64 ,Process, Value);
        {$ENDIF}
        Result := True;
      end;
      tiOleTlsData:
      begin
        {$IFDEF WIN32}
        Add(DumpOleTlsData32, Process, Value);
        {$ELSE}
        if Use32AddrMode then
          Add(DumpOleTlsData32, Process, Value)
        else
          Add(DumpOleTlsData64, Process, Value);
        {$ENDIF}
        Result := True;
      end;
    else
      Result := False;
    end;
  end;

const
  DAsmModeStr: array [Boolean] of string = ('x86', 'x64');

var
  MBI: TMemoryBasicInformation;
  dwLength: Cardinal;
  ProcessLock: TProcessLockHandleList;
  Index: Integer;
  ARegion: TRegionData;
  Item: TContainItem;
  Dasm64Mode: Boolean;
begin
  CurerntAddr := Value;
  ProcessLock := nil;
  Process := OpenProcessWithReconnect;
  try
    Caption := Format(DefCaption, [ULONG_PTR(Value)]);
    edProperties.Lines.Add('Info at address: ' + UInt64ToStr(ULONG_PTR(Value)));
    if Settings.SuspendProcess then
      ProcessLock := SuspendProcess(MemoryMapCore.PID);
    try
      dwLength := SizeOf(TMemoryBasicInformation);
      if VirtualQueryEx(Process,
         Pointer(Value), MBI, dwLength) <> dwLength then
         RaiseLastOSError;

      ShowInfoFromMBI(Process, MBI, Value);

      if ShowAsDisassembly then
      begin
        Add(Disassembly(Process, Value, DAsmMode, Dasm64Mode));
        Caption := Caption + ' Mode: ' + DAsmModeStr[Dasm64Mode];
        Exit;
      end;

      {$MESSAGE 'Все структуры перенести в SymbolStorage'}

      if Value = KUSER_SHARED_DATA_ADDR then
      begin
        Add(DumpKUserSharedData, Process, Value);
        Caption := Caption + ' KUSER_SHARED_DATA';
        Exit;
      end;

      {$IFDEF WIN64}
      if Value = MemoryMapCore.PebWow64BaseAddress then
      begin
        Add(DumpPEB32, Process, Value);
        Caption := Caption + ' PebWow64';
        Exit;
      end;
      {$ENDIF}

      if Value = MemoryMapCore.PebBaseAddress then
      begin
        {$IFDEF WIN32}
        Add(DumpPEB32 ,Process, Value);
        Caption := Caption + ' Peb32';
        {$ELSE}
        Add(DumpPEB64, Process, Value);
        Caption := Caption + ' Peb64';
        {$ENDIF}
        Exit;
      end;

      if CheckPEImage(Process, Value) then
      begin
        Add(DumpPEHeader, Process, Value);
        Exit;
      end;

      // вывод информации с которой начинается регион (описана непосредственно в Region)
      if MemoryMapCore.GetRegionIndex(Value, Index) then
      begin
        ARegion := MemoryMapCore.GetRegionAtUnfilteredIndex(Index);
        if (ARegion.RegionType = rtThread) then
          if CheckThreadData(ARegion.Thread.Flag, ARegion.Thread.Wow64) then
            Exit;
      end;

      // вывод информации которая является частью региона (находится в Region.Contains)
      if MemoryMapCore.GetRegionIndex(GetPageAddr, Index) then
      begin
        ARegion := MemoryMapCore.GetRegionAtUnfilteredIndex(Index);
        if (ARegion.RegionType = rtThread) then
          for Item in ARegion.Contains do
            case Item.ItemType of
              itThreadData:
              begin
                if (Item.ThreadData.Address = Value) and
                (CheckThreadData(Item.ThreadData.Flag, Item.ThreadData.Wow64)) then
                  Exit;
              end;
            end;
      end;

      {$IFDEF WIN64}
      if Value = Pointer(MemoryMapCore.PEBWow64.ProcessParameters) then
      begin
        Add(DumpProcessParameters32, Process, Value);
        Caption := Caption + ' ProcessParameters32';
        Exit;
      end;
      {$ENDIF}

      if Value = MemoryMapCore.PEB.ProcessParameters then
      begin
        {$IFDEF WIN32}
        Add(DumpProcessParameters32, Process, Value);
        Caption := Caption + ' ProcessParameters32';
        {$ELSE}
        Add(DumpProcessParameters64, Process, Value);
        Caption := Caption + ' ProcessParameters64';
        {$ENDIF}
        Exit;
      end;

      Add(DumpMemory, Process, Value);
    finally
      edProperties.SelStart := 0;
      if Settings.SuspendProcess then
        ResumeProcess(ProcessLock);
    end;
  finally
    CloseHandle(Process);
  end;
end;

procedure TdlgRegionProps.mnuDasmModeAutoClick(Sender: TObject);
var
  NewDAsmMode: TDasmMode;
begin
  NewDAsmMode := TDasmMode(TMenuItem(Sender).Tag);
  if DAsmMode = NewDAsmMode then Exit;
  DAsmMode := NewDAsmMode;
  TMenuItem(Sender).Checked := True;
  if mnuShowAsDisassembly.Checked then
  begin
    edProperties.Lines.BeginUpdate;
    try
      edProperties.Lines.Clear;
      StartQuery(CurerntAddr);
    finally
      edProperties.Lines.EndUpdate;;
    end;
  end;
end;

end.
