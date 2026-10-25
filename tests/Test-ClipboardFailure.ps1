#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$EnspPath)

$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -eq 'Core') {
    throw 'Run this developer test with Windows PowerShell 5.1 (powershell.exe).'
}
$source=@'

using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.ComponentModel;

public static class ClipboardFailureProbe {
    static class Win32 {
        [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetProcessWindowStation();
        [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateWindowStationW(string name,uint flags,uint access,IntPtr security);
        [DllImport("user32.dll",SetLastError=true)] public static extern bool SetProcessWindowStation(IntPtr station);
        [DllImport("user32.dll",SetLastError=true)] public static extern bool CloseWindowStation(IntPtr station);
        [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string name,IntPtr device,IntPtr mode,uint flags,uint access,IntPtr security);
        [DllImport("user32.dll",SetLastError=true)] public static extern bool SetThreadDesktop(IntPtr desktop);
        [DllImport("user32.dll",SetLastError=true)] public static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint thread);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool GetUserObjectInformationW(IntPtr obj,int index,StringBuilder text,uint size,out uint needed);
        [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateWindowExW(uint ex,string cls,string title,uint style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
        [DllImport("user32.dll",SetLastError=true)] public static extern bool DestroyWindow(IntPtr window);
        [DllImport("user32.dll",SetLastError=true)] public static extern bool OpenClipboard(IntPtr window);
        [DllImport("user32.dll",SetLastError=true)] public static extern bool CloseClipboard();
        [DllImport("user32.dll",SetLastError=true)] public static extern bool EmptyClipboard();
        [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetClipboardData(uint format);
        [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SetClipboardData(uint format,IntPtr memory);
        [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern uint RegisterClipboardFormatW(string name);
        [DllImport("user32.dll")] public static extern bool IsClipboardFormatAvailable(uint format);
        [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr GlobalAlloc(uint flags,UIntPtr size);
        [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr GlobalLock(IntPtr memory);
        [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr memory);
        [DllImport("kernel32.dll")] public static extern IntPtr GlobalFree(IntPtr memory);
        [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr VirtualAlloc(IntPtr address,UIntPtr size,uint allocation,uint protection);
        [DllImport("kernel32.dll",SetLastError=true)] public static extern bool VirtualFree(IntPtr memory,UIntPtr size,uint type);
        [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] public static extern bool FlushInstructionCache(IntPtr process,IntPtr address,UIntPtr size);
    }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    [return:MarshalAs(UnmanagedType.Bool)]
    delegate bool OpenCall(IntPtr window);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate IntPtr ReadCall(uint format);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    [return:MarshalAs(UnmanagedType.Bool)]
    delegate bool CloseCall();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate IntPtr PasteCall(IntPtr output,IntPtr window);

    static void Require(bool ok,string message) { if(!ok) throw new InvalidOperationException(message); }
    static void NativeRequire(bool ok,string message) {
        if(!ok) { int error=Marshal.GetLastWin32Error(); throw new Win32Exception(error,message+" (Win32 "+error+")"); }
    }
    static string ObjectName(IntPtr obj) {
        var value=new StringBuilder(256); uint needed;
        NativeRequire(Win32.GetUserObjectInformationW(obj,2,value,512,out needed),"GetUserObjectInformation");
        return value.ToString();
    }
    static bool OtherThreadCanOpen() {
        bool opened=false;
        var thread=new Thread(delegate() {
            opened=Win32.OpenClipboard(IntPtr.Zero);
            if(opened) Win32.CloseClipboard();
        });
        thread.IsBackground=true; thread.Start();
        Require(thread.Join(3000),"Clipboard probe thread timed out.");
        return opened;
    }
    static void SeedNonText(IntPtr window) {
        NativeRequire(Win32.OpenClipboard(window),"Open private clipboard");
        IntPtr memory=IntPtr.Zero;
        try {
            NativeRequire(Win32.EmptyClipboard(),"Empty private clipboard");
            uint format=Win32.RegisterClipboardFormatW("eNSP.ClientFix.IsolatedTest");
            Require(format!=0,"Register private format failed.");
            memory=Win32.GlobalAlloc(2,new UIntPtr(1));
            NativeRequire(memory!=IntPtr.Zero,"Allocate private test data");
            IntPtr data=Win32.GlobalLock(memory);
            NativeRequire(data!=IntPtr.Zero,"Lock private test data");
            Marshal.WriteByte(data,42); Win32.GlobalUnlock(memory);
            NativeRequire(Win32.SetClipboardData(format,memory)!=IntPtr.Zero,"Set private test data");
            memory=IntPtr.Zero;
        } finally {
            if(memory!=IntPtr.Zero) Win32.GlobalFree(memory);
            Win32.CloseClipboard();
        }
        Require(!Win32.IsClipboardFormatAvailable(1),"Private clipboard unexpectedly contains text.");
    }

    // Execute the audited x86 function's failure paths. Relocate its API slots
    // and replace only CString initialization, which precedes clipboard access.
    // Success-only MFC conversion paths are deliberately outside this test.
    sealed class FunctionProbe : IDisposable {
        public int OpenCalls,ReadCalls,CloseCalls;
        public bool Opened,ReadWasNull;
        IntPtr memory;
        OpenCall open; ReadCall read; CloseCall close; PasteCall paste;
        static IntPtr At(IntPtr pointer,int offset) { return IntPtr.Add(pointer,offset); }
        public FunctionProbe(byte[] original,bool patched) {
            memory=Win32.VirtualAlloc(IntPtr.Zero,new UIntPtr(4096),0x3000,0x40);
            NativeRequire(memory!=IntPtr.Zero,"Allocate isolated native function");
            byte[] code=(byte[])original.Clone();
            Require(code[0x48]==0xE8 && code[0x65]==0xFF && code[0x74]==0xFF && code[0xFE]==0xFF,"Unexpected function layout.");
            code[0x80]=(byte)(patched?0x7A:0xB6);
            open=delegate(IntPtr window) { OpenCalls++; Opened=Win32.OpenClipboard(window); return Opened; };
            read=delegate(uint format) {
                ReadCalls++;
                IntPtr value=Win32.GetClipboardData(format);
                ReadWasNull=(value==IntPtr.Zero);
                // Force the bounded failure path if unexpected data appears;
                // the test subsequently fails its ReadWasNull assertion.
                return IntPtr.Zero;
            };
            close=delegate() { CloseCalls++; return Win32.CloseClipboard(); };
            Marshal.WriteIntPtr(At(memory,0x380),Marshal.GetFunctionPointerForDelegate(open));
            Marshal.WriteIntPtr(At(memory,0x384),Marshal.GetFunctionPointerForDelegate(read));
            Marshal.WriteIntPtr(At(memory,0x388),Marshal.GetFunctionPointerForDelegate(close));
            Marshal.WriteInt32(At(memory,0x390),0x12345678);
            // Empty CString buffer: length at data-12 is zero.
            IntPtr empty=At(memory,0x3D0);
            byte[] ctor={0xC7,0x01,0,0,0,0,0x8B,0xC1,0xC2,0x04,0x00};
            Buffer.BlockCopy(BitConverter.GetBytes(empty.ToInt32()),0,ctor,2,4);
            Marshal.Copy(ctor,0,At(memory,0x300),ctor.Length);
            // ExceptionContinueSearch; unexpected native exceptions fail the helper.
            Marshal.Copy(new byte[]{0xB8,1,0,0,0,0xC3},0,At(memory,0x320),6);
            Patch(code,0x03,At(memory,0x320).ToInt32());
            Patch(code,0x19,At(memory,0x390).ToInt32());
            Patch(code,0x3E,empty.ToInt32());
            Patch(code,0x49,unchecked(At(memory,0x300).ToInt32()-At(memory,0x4D).ToInt32()));
            Patch(code,0x67,At(memory,0x380).ToInt32());
            Patch(code,0x76,At(memory,0x384).ToInt32());
            Patch(code,0x100,At(memory,0x388).ToInt32());
            Marshal.Copy(code,0,memory,code.Length);
            Win32.FlushInstructionCache(Win32.GetCurrentProcess(),memory,new UIntPtr(4096));
            paste=(PasteCall)Marshal.GetDelegateForFunctionPointer(memory,typeof(PasteCall));
        }
        static void Patch(byte[] data,int offset,int value) { Buffer.BlockCopy(BitConverter.GetBytes(value),0,data,offset,4); }
        public void Invoke(IntPtr window) { paste(At(memory,0x3E0),window); }
        public void Dispose() {
            GC.KeepAlive(open); GC.KeepAlive(read); GC.KeepAlive(close); GC.KeepAlive(paste);
            if(memory!=IntPtr.Zero) { Win32.VirtualFree(memory,UIntPtr.Zero,0x8000); memory=IntPtr.Zero; }
        }
    }
    static void TestMissingText(byte[] function,IntPtr window,bool patched) {
        using(var probe=new FunctionProbe(function,patched)) {
            try {
                probe.Invoke(window);
                bool available=OtherThreadCanOpen();
                Console.WriteLine((patched?"Patched":"Original")+": opened="+probe.Opened+", readNull="+probe.ReadWasNull+", closeCalls="+probe.CloseCalls+", otherThreadCanOpen="+available);
                Require(probe.OpenCalls==1 && probe.Opened && probe.ReadCalls==1 && probe.ReadWasNull,"Expected the real missing-text API result.");
                Require(probe.CloseCalls==(patched?1:0),"Unexpected CloseClipboard call count.");
                Require(available==patched,"The expected clipboard lock/release behavior was not reproduced.");
            } finally { if(probe.Opened && probe.CloseCalls==0) Win32.CloseClipboard(); }
        }
    }
    static void TestOpenFailure(byte[] function,IntPtr window) {
        using(var ready=new ManualResetEvent(false))
        using(var release=new ManualResetEvent(false))
        using(var probe=new FunctionProbe(function,true)) {
            bool held=false;
            var holder=new Thread(delegate() {
                held=Win32.OpenClipboard(IntPtr.Zero); ready.Set();
                try { if(held) release.WaitOne(10000); }
                finally { if(held) Win32.CloseClipboard(); }
            });
            holder.IsBackground=true; holder.Start();
            try {
                Require(ready.WaitOne(3000) && held,"Failed to hold the private clipboard for the open-failure case.");
                probe.Invoke(window);
                Require(probe.OpenCalls==1 && !probe.Opened && probe.ReadCalls==0 && probe.CloseCalls==0,"OpenClipboard failure path changed.");
                Console.WriteLine("Patched open failure: readCalls=0, closeCalls=0; existing lock preserved.");
            } finally { release.Set(); Require(holder.Join(3000),"Holder thread did not finish."); }
        }
        Require(OtherThreadCanOpen(),"Private clipboard was not released after the holder finished.");
    }

    public static int Main(string[] args) {
        IntPtr oldStation=IntPtr.Zero,oldDesktop=IntPtr.Zero,station=IntPtr.Zero,desktop=IntPtr.Zero,window=IntPtr.Zero;
        try {
            Require(IntPtr.Size==4,"This helper must run as x86.");
            Require(args.Length==1,"Expected one local eNSP executable path.");
            byte[] file=File.ReadAllBytes(args[0]);
            string hash;
            using(var sha=SHA256.Create()) hash=BitConverter.ToString(sha.ComputeHash(file)).Replace("-","").ToLowerInvariant();
            string[] allowed={
                "e2cdd4c77eaca23fbc84c9e466e6847988cc42a349df3ede0b65c1c1f8080b7e",
                "8bf1ad0d35310905020b20f0ffef419e34f685c90666162de762006df176d20f",
                "e567ddfabd65000b440211dd5e5a3b149b36e766c7619daaf0fdcd0ea65e230b",
                "50e64999d0f3e9937fb8131066dd22615eda90c64b7bbdd64d5b4b937d2e4ed7"
            };
            Require(Array.IndexOf(allowed,hash)>=0 && file.Length==3547136,"Unsupported executable.");
            byte[] function=new byte[0x156]; Buffer.BlockCopy(file,0xD5A10,function,0,function.Length);
            string name="ensp-clip-test-"+Guid.NewGuid().ToString("N");
            oldStation=Win32.GetProcessWindowStation();
            oldDesktop=Win32.GetThreadDesktop(Win32.GetCurrentThreadId());
            station=Win32.CreateWindowStationW(name,0,0xF037F,IntPtr.Zero);
            NativeRequire(station!=IntPtr.Zero,"Create isolated window station");
            NativeRequire(Win32.SetProcessWindowStation(station),"Select isolated window station");
            desktop=Win32.CreateDesktopW("Probe",IntPtr.Zero,IntPtr.Zero,0,0xF01FF,IntPtr.Zero);
            NativeRequire(desktop!=IntPtr.Zero,"Create isolated desktop");
            NativeRequire(Win32.SetThreadDesktop(desktop),"Select isolated desktop");
            // Hard gate: no clipboard API is called before exact isolation verification.
            Require(ObjectName(Win32.GetProcessWindowStation())==name,"Clipboard isolation was not established.");
            Require(ObjectName(Win32.GetThreadDesktop(Win32.GetCurrentThreadId()))=="Probe","Desktop isolation was not established.");
            Console.WriteLine("Isolated window station: "+name);
            window=Win32.CreateWindowExW(0,"STATIC","Private clipboard test",0,0,0,1,1,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
            NativeRequire(window!=IntPtr.Zero,"Create private clipboard window");
            SeedNonText(window);
            TestMissingText(function,window,false);
            TestMissingText(function,window,true);
            TestOpenFailure(function,window);
            Console.WriteLine("PASS: original failure path locks the private clipboard; the repaired path releases it.");
            return 0;
        } catch(Exception exception) {
            Console.Error.WriteLine(exception.ToString());
            return 1;
        } finally {
            if(window!=IntPtr.Zero) Win32.DestroyWindow(window);
            if(oldStation!=IntPtr.Zero) Win32.SetProcessWindowStation(oldStation);
            if(oldDesktop!=IntPtr.Zero) Win32.SetThreadDesktop(oldDesktop);
            if(desktop!=IntPtr.Zero) Win32.CloseDesktop(desktop);
            if(station!=IntPtr.Zero) Win32.CloseWindowStation(station);
        }
    }
}

'@
$target=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $EnspPath).ProviderPath)
$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tempRoot=Join-Path $tempParent ('ensp-native-test-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $tempRoot){throw 'Test directory already exists.'}
try {
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $executable=Join-Path $tempRoot 'ClipboardFailureProbe.exe'
    $provider=New-Object Microsoft.CSharp.CSharpCodeProvider
    $parameters=New-Object CodeDom.Compiler.CompilerParameters
    $parameters.GenerateExecutable=$true
    $parameters.GenerateInMemory=$false
    $parameters.OutputAssembly=$executable
    $parameters.CompilerOptions='/platform:x86 /optimize'
    [void]$parameters.ReferencedAssemblies.Add('System.dll')
    try { $compiled=$provider.CompileAssemblyFromSource($parameters,$source) }
    finally { $provider.Dispose() }
    if($compiled.Errors.HasErrors){throw ($compiled.Errors | Out-String)}
    & $executable $target
    if($LASTEXITCODE -ne 0){throw 'Isolated native clipboard verification failed.'}
} finally {
    if(Test-Path -LiteralPath $tempRoot){
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $tempRoot).ProviderPath)
        if(-not $resolved.StartsWith($tempParent+'\',[StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notmatch '^ensp-native-test-[a-f0-9]{32}$'){
            throw 'Refusing to clean an unexpected directory.'
        }
        $items=@((Get-Item -LiteralPath $resolved -Force))+@(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
        if($items | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){
            throw 'Refusing to clean a reparse point.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
exit 0
