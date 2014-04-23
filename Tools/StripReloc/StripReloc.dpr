program StripReloc;

{$APPTYPE CONSOLE}

{
  StripReloc v1.13
  Strip relocation section from Win32 PE files
  Copyright (C) 1999-2005 Jordan Russell. All rights reserved.
  http://www.jrsoftware.org/

  This program is free software; you can redistribute it and/or
  modify it under the terms of the GNU General Public License
  as published by the Free Software Foundation; either version 2
  of the License, or (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

  $jrsoftware: stripreloc/StripReloc.dpr,v 1.16 2005/02/13 05:03:42 jr Exp $
}

uses
  Windows, SysUtils, Classes;

const
  Version = '1.13';

var
  KeepBackups: Boolean = True;
  WantValidChecksum: Boolean = False;
  ForceStrip: Boolean = False;

  ImageHlpHandle: THandle;
  CheckSumMappedFile: function(BaseAddress: Pointer; FileLength: DWORD;
    var HeaderSum: DWORD; var CheckSum: DWORD): PImageNtHeaders; stdcall;

function CalcChecksum(const FileHandle: THandle): DWORD;
var
  Size: DWORD;
  H: THandle;
  M: Pointer;
  OldSum: DWORD;
begin
  Size := GetFileSize(FileHandle, nil);
  H := CreateFileMapping(FileHandle, nil, PAGE_READONLY, 0, Size, nil);
  if H = 0 then RaiseLastOSError;
  try
    M := MapViewOfFile(H, FILE_MAP_READ, 0, 0, Size);
    if M = nil then RaiseLastOSError;
    try
      Win32Check(CheckSumMappedFile(M, Size, OldSum, Result) <> nil);
    finally
      UnmapViewOfFile(M);
    end;
  finally
    CloseHandle(H);
  end;
end;

procedure Strip(const Filename: string);
const
  IMAGE_NT_OPTIONAL_HDR32_MAGIC = $10b;
type
  PPESectionHeaderArray = ^TPESectionHeaderArray;
  TPESectionHeaderArray = array[0..$7FFFFFFF div SizeOf(TImageSectionHeader)-1] of TImageSectionHeader;
var
  BackupFilename: string;
  F, F2: file;
  EXESig: Word;
  PEHeaderOffset, PESig: Cardinal;
  PEHeader: TImageFileHeader;
  PEOptHeader: TImageOptionalHeader;
  PESectionHeaders: PPESectionHeaderArray;
  BytesLeft, Bytes: Cardinal;
  Buf: array[0..8191] of Byte;
  I: Integer;
  RelocVirtualAddr, RelocPhysOffset, RelocPhysSize: Cardinal;
  OldSize, NewSize: Cardinal;
  TimeStamp: TFileTime;
begin
  PESectionHeaders := nil;
  try
    RelocPhysOffset := 0;
    RelocPhysSize := 0;
    BackupFilename := Filename + '.bak';

    Write(Filename, ': ');
    AssignFile(F, Filename);
    FileMode := fmOpenRead or fmShareDenyWrite;
    Reset(F, 1);
    try
      OldSize := FileSize(F);
      GetFileTime(TFileRec(F).Handle, nil, nil, @TimeStamp);

      BlockRead(F, EXESig, SizeOf(EXESig));
      if EXESig <> $5A4D {'MZ'} then
      begin
        Writeln('File isn''t an EXE file (1).');
        Exit;
      end;
      Seek(F, $3C);
      BlockRead(F, PEHeaderOffset, SizeOf(PEHeaderOffset));
      if PEHeaderOffset = 0 then
      begin
        Writeln('File isn''t a PE file (1).');
        Exit;
      end;
      Seek(F, PEHeaderOffset);
      BlockRead(F, PESig, SizeOf(PESig));
      if PESig <> $00004550 {'PE'#0#0} then
      begin
        Writeln('File isn''t a PE file (2).');
        Exit;
      end;
      BlockRead(F, PEHeader, SizeOf(PEHeader));
      if not ForceStrip and (PEHeader.Characteristics and IMAGE_FILE_DLL <> 0) then
      begin
        Writeln('Skipping; can''t strip a DLL.');
        Exit;
      end;
      if PEHeader.Characteristics and IMAGE_FILE_RELOCS_STRIPPED <> 0 then
      begin
        Writeln('Relocations already stripped from file (1).');
        Exit;
      end;
      PEHeader.Characteristics := PEHeader.Characteristics or IMAGE_FILE_RELOCS_STRIPPED;
      if PEHeader.SizeOfOptionalHeader <> SizeOf(PEOptHeader) then
      begin
        Writeln('File isn''t a valid 32-bit image (1).');
        Exit;
      end;
      BlockRead(F, PEOptHeader, SizeOf(PEOptHeader));
      if PEOptHeader.Magic <> IMAGE_NT_OPTIONAL_HDR32_MAGIC then
      begin
        Writeln('File isn''t a valid 32-bit image (2).');
        Exit;
      end;
      if (PEOptHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC].VirtualAddress = 0) or
         (PEOptHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC].Size = 0) then
      begin
        Writeln('Relocations already stripped from file (2).');
        Exit;
      end;
      RelocVirtualAddr := PEOptHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC].VirtualAddress;
      PEOptHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC].VirtualAddress := 0;
      PEOptHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC].Size := 0;
      if not WantValidChecksum then PEOptHeader.CheckSum := 0;
      GetMem(PESectionHeaders, PEHeader.NumberOfSections * SizeOf(TImageSectionHeader));
      BlockRead(F, PESectionHeaders^, PEHeader.NumberOfSections * SizeOf(TImageSectionHeader));
      for I := 0 to PEHeader.NumberOfSections-1 do
      begin
        with PESectionHeaders[I] do
        begin
          if (VirtualAddress = RelocVirtualAddr) and (SizeOfRawData <> 0) then
          begin
            RelocPhysOffset := PointerToRawData;
            RelocPhysSize := SizeOfRawData;
            SizeOfRawData := 0;
            Break;
          end;
        end;
      end;
      if RelocPhysOffset = 0 then
      begin
        Writeln('Relocations already stripped from file (3).');
        Exit;
      end;
      if RelocPhysSize = 0 then
      begin
        Writeln('Relocations already stripped from file (4).');
        Exit;
      end;
      for I := 0 to PEHeader.NumberOfSections-1 do
        with PESectionHeaders[I] do
        begin
          if PointerToRawData > RelocPhysOffset then Dec(PointerToRawData, RelocPhysSize);
          if PointerToLinenumbers > RelocPhysOffset then Dec(PointerToLinenumbers, RelocPhysSize);
          if PointerToRelocations <> 0 then
          begin
            { ^ I don't think this field is ever used in the PE format.
              StripRlc doesn't handle it. }
            Writeln('Cannot handle this file (1).');
            Exit;
          end;
        end;
      if PEOptHeader.ImageBase < $400000 then
      begin
        Writeln('Cannot handle this file -- the image base address is less than 0x400000.');
        Exit;
      end;
    finally
      CloseFile(F);
    end;
    if FileExists(BackupFilename) then Win32Check(DeleteFile(BackupFilename));
    Rename(F, BackupFilename);
    try
      FileMode := fmOpenRead or fmShareDenyWrite;
      Reset(F, 1);
      try
        AssignFile(F2, Filename);
        FileMode := fmOpenWrite or fmShareExclusive;
        Rewrite(F2, 1);
        try
          BytesLeft := RelocPhysOffset;
          while BytesLeft <> 0 do
          begin
            Bytes := BytesLeft;
            if Bytes > SizeOf(Buf) then Bytes := SizeOf(Buf);
            BlockRead(F, Buf, Bytes);
            BlockWrite(F2, Buf, Bytes);
            Dec(BytesLeft, Bytes);
          end;
          Seek(F, Cardinal(FilePos(F)) + RelocPhysSize);
          BytesLeft := FileSize(F) - FilePos(F);
          while BytesLeft <> 0 do
          begin
            Bytes := BytesLeft;
            if Bytes > SizeOf(Buf) then Bytes := SizeOf(Buf);
            BlockRead(F, Buf, Bytes);
            BlockWrite(F2, Buf, Bytes);
            Dec(BytesLeft, Bytes);
          end;
          Seek(F2, PEHeaderOffset + SizeOf(PESig));
          BlockWrite(F2, PEHeader, SizeOf(PEHeader));
          BlockWrite(F2, PEOptHeader, SizeOf(PEOptHeader));
          BlockWrite(F2, PESectionHeaders^, PEHeader.NumberOfSections * SizeOf(TImageSectionHeader));
          if WantValidChecksum then
          begin
            PEOptHeader.CheckSum := CalcChecksum(TFileRec(F2).Handle);
            { go back and rewrite opt. header with new checksum }
            Seek(F2, PEHeaderOffset + SizeOf(PESig) + SizeOf(PEHeader));
            BlockWrite(F2, PEOptHeader, SizeOf(PEOptHeader));
          end;
          NewSize := FileSize(F2);
          SetFileTime(TFileRec(F2).Handle, nil, nil, @TimeStamp);
        finally
          CloseFile(F2);
        end;
      finally
        CloseFile(F);
      end;
    except
      DeleteFile(Filename);
      AssignFile(F, BackupFilename);
      Rename(F, Filename);
      raise;
    end;
    Writeln(OldSize, ' -> ', NewSize, ' bytes (', OldSize - NewSize, ' difference)');
    if not KeepBackups and not DeleteFile(BackupFilename) then
    begin
      Writeln('Warning: Couldn''t delete backup file ', BackupFilename);
    end;
  finally
    FreeMem(PESectionHeaders);
  end;
end;

var
  SR: TSearchRec;
  S: string;
  FilesList: TStringList;
  P, I: Integer;
  HasFileParameter: Boolean = False;
  NumFiles: Integer = 0;
  
label __Usage;

begin
  try
    Writeln('StripReloc v' + Version + ', Copyright (C) 1999-2005 Jordan Russell, www.jrsoftware.org');
    if ParamCount = 0 then
    begin
      Writeln('Strip relocation section from Win32 PE files');
      Writeln;
      __Usage:
      Writeln('usage:     stripreloc [switches] filename.exe');
      Writeln;
      Writeln('switches:  /B  don''t create .bak backup files');
      Writeln('           /C  write a valid checksum in the header (instead of zero)');
      Writeln('           /F  force stripping DLLs instead of skipping them. do not use!');
      Readln;
    end;
    Writeln;

    for P := 1 to ParamCount do
    begin
      S := ParamStr(P);
      if S[1] <> '/' then Continue;
      Delete(S, 1, 1);
      I := 1;
      while I <= Length(S) do
      begin
        case UpCase(S[I]) of
          '?': goto __Usage;
          'B': begin
                 KeepBackups := False;
                 if I < Length(S) then
                 begin
                   { For backward compatibility, do keep backups if the character
                     following 'B' is a '+'. }
                   if S[I+1] = '+' then
                   begin
                     KeepBackups := True;
                     Inc(I);
                   end
                   else if S[I+1] = '-' then
                   begin
                     Inc(I);
                   end;
                 end;
               end;
          'C': if not WantValidChecksum then
               begin
                 ImageHlpHandle := LoadLibrary('imagehlp.dll');
                 if ImageHlpHandle = 0 then
                 begin
                   Writeln('Error: Unable to load imagehlp.dll.');
                   Writeln('       It is required when using the /C parameter.');
                   Halt(1);
                 end;
                 CheckSumMappedFile := GetProcAddress(ImageHlpHandle, 'CheckSumMappedFile');
                 if @CheckSumMappedFile = nil then
                 begin
                   Writeln('Error: Unable to get address of CheckSumMappedFile in imagehlp.dll.');
                   Writeln('       It is required when using the /C parameter.');
                   Halt(1);
                 end;
                 WantValidChecksum := True;
               end;
          'F': ForceStrip := True;
        else
          Writeln('Invalid parameter: /', S[I]);
          Halt(1);
        end;
        Inc(I);
      end;
    end;

    for P := 1 to ParamCount do
    begin
      S := ParamStr(P);
      if S[1] = '/' then Continue;
      HasFileParameter := True;
      FilesList := TStringList.Create;
      try
        FilesList.Sorted := True;
        if LastDelimiter('*?', S) = 0 then
        begin
          if GetFileAttributes(PChar(S)) and FILE_ATTRIBUTE_DIRECTORY <> 0 then
          begin
            { This'll catch non-existant files as well as directory names }
            Writeln(S, ': File not found.');
            Continue;
          end;
          FilesList.Add(S);
        end
        else begin
          if FindFirst(S, 0, SR) <> 0 then
          begin
            Writeln('No files matching "', S, '" found.');
            Continue;
          end;
          try
            repeat
              if CompareText(ExtractFileExt(SR.Name), '.bak') <> 0 then
                FilesList.Add(ExtractFilePath(S) + SR.Name);
            until FindNext(SR) <> 0;
          finally
            FindClose(SR);
          end;
        end;
        for I := 0 to FilesList.Count-1 do
        begin
          Strip(FilesList[I]);
        end;
        Inc(NumFiles);
      finally
        FilesList.Free;
      end;
    end;
    if not HasFileParameter then goto __Usage;
    if NumFiles = 0 then Halt(1);
  except
    on E: Exception do
    begin
      Writeln('Fatal error: ', E.Message);
      Halt(2);
    end;
  end;
end.
