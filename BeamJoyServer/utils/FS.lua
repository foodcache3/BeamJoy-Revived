-- FS lib additions

---@param path string
local function removeDirectoryNative(path)
    if not FS.Exists(path) or not FS.IsDirectory(path) then return end
    for _, file in pairs(FS.ListFiles(path)) do
        FS.Remove(path .. "/" .. file)
    end
    for _, folder in pairs(FS.ListDirectories(path)) do
        removeDirectoryNative(path .. "/" .. folder)
    end
    FS.Remove(path)
end

FS.isWindows = FS.isWindows or function()
    local sep = package.config:sub(1, 1)
    return sep == "\\"
end

--- Converts a UTF-8 Lua string to a raw UTF-16LE byte string (with surrogate pairs for
--- codepoints outside the BMP). Needed so a Unicode archive/destination path (e.g. a custom
--- map's zip file named with non-ASCII characters) can be handed to PowerShell via
--- -EncodedCommand instead of as literal text on the os.execute command line: os.execute's
--- underlying system() call converts that whole line through the OS's current ANSI codepage,
--- which throws "No mapping for the Unicode character exists in the target multi-byte code
--- page" the moment a path contains a character that codepage can't represent.
---@param str string
---@return string
local function utf8ToUtf16LE(str)
    local out = {}
    local i, len = 1, #str
    while i <= len do
        local b1 = str:byte(i)
        local cp, seqLen
        if b1 < 0x80 then
            cp, seqLen = b1, 1
        elseif b1 >= 0xF0 then
            local b2, b3, b4 = str:byte(i + 1, i + 3)
            cp = (b1 % 0x08) * 0x40000 + (b2 % 0x40) * 0x1000 + (b3 % 0x40) * 0x40 + (b4 % 0x40)
            seqLen = 4
        elseif b1 >= 0xE0 then
            local b2, b3 = str:byte(i + 1, i + 2)
            cp = (b1 % 0x10) * 0x1000 + (b2 % 0x40) * 0x40 + (b3 % 0x40)
            seqLen = 3
        elseif b1 >= 0xC0 then
            local b2 = str:byte(i + 1)
            cp = (b1 % 0x20) * 0x40 + (b2 % 0x40)
            seqLen = 2
        else
            -- stray continuation byte, treat as a raw latin1 codepoint rather than erroring
            cp, seqLen = b1, 1
        end
        i = i + seqLen

        if cp < 0x10000 then
            out[#out + 1] = string.char(cp % 0x100, math.floor(cp / 0x100))
        else
            cp = cp - 0x10000
            local hi, lo = 0xD800 + math.floor(cp / 0x400), 0xDC00 + (cp % 0x400)
            out[#out + 1] = string.char(hi % 0x100, math.floor(hi / 0x100))
            out[#out + 1] = string.char(lo % 0x100, math.floor(lo / 0x100))
        end
    end
    return table.concat(out)
end

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Minimal, self-contained base64 encoder, deliberately NOT using utils_sha's own
--- bin_to_base64 : this file is require()'d at the very top of BeamJoyServer.lua specifically so
--- it's usable standalone before the dependency system runs, but FS.RemoveDirectory is called
--- from checkWritePermissions() even earlier than that, before utils_sha (loaded as part of that
--- same dependency system) exists in _G at all. Reaching for it here would throw "attempt to
--- index a nil value" the moment the server starts.
---@param data string raw bytes
---@return string
local function toBase64(data)
    local out = {}
    for i = 1, #data, 3 do
        local b1, b2, b3 = data:byte(i, i + 2)
        local n = b1 * 0x10000 + (b2 or 0) * 0x100 + (b3 or 0)
        out[#out + 1] = B64_CHARS:sub(math.floor(n / 0x40000) % 0x40 + 1, math.floor(n / 0x40000) % 0x40 + 1)
        out[#out + 1] = B64_CHARS:sub(math.floor(n / 0x1000) % 0x40 + 1, math.floor(n / 0x1000) % 0x40 + 1)
        out[#out + 1] = b2 and B64_CHARS:sub(math.floor(n / 0x40) % 0x40 + 1, math.floor(n / 0x40) % 0x40 + 1) or "="
        out[#out + 1] = b3 and B64_CHARS:sub(n % 0x40 + 1, n % 0x40 + 1) or "="
    end
    return table.concat(out)
end

--- Runs a PowerShell script via -EncodedCommand (UTF-16LE + base64), so the script text never
--- has to survive an ANSI-codepage conversion on the os.execute command line itself: see
--- utf8ToUtf16LE's own comment for why that conversion is otherwise unsafe for Unicode paths.
---@param script string
local function runPowerShell(script)
    local encoded = toBase64(utf8ToUtf16LE(script))
    os.execute("powershell -NoProfile -NonInteractive -EncodedCommand " .. encoded)
end

--- Removes a directory tree. On Windows this goes through PowerShell's own Remove-Item rather
--- than the native FS.ListFiles/FS.Remove walk : those native (BeamMP-Server host) bindings can
--- themselves throw "No mapping for the Unicode character exists in the target multi-byte code
--- page" for a genuinely Unicode-named file (eg. leftover content from a previously-extracted
--- mod archive). A real, observed failure distinct from the os.execute/ANSI-codepage issue
--- fixed elsewhere in this file, since it happens on plain file removal, no command-line
--- interpolation involved at all. Left unresolved, this doesn't just fail once : since callers
--- (eg. services/maps.lua's mod scan) reuse the same scratch folder across every mod they
--- analyze, one Unicode-named leftover the native walk can't clean up stays there and breaks
--- every subsequent caller's own attempt to clear that same folder too. PowerShell's own file
--- APIs are Unicode-safe regardless of the OS's active ANSI codepage, so routing through it
--- sidesteps the whole class of bug instead of trying to catch it after the fact.
---@param path string
FS.RemoveDirectory = FS.RemoveDirectory or function(path)
    if FS.isWindows() then
        local escaped = path:gsub("'", "''")
        runPowerShell(string.format(
            "if (Test-Path -LiteralPath '%s') { Remove-Item -LiteralPath '%s' -Recurse -Force }",
            escaped, escaped))
    else
        removeDirectoryNative(path)
    end
end

---@param archivePath string
---@param dstPath string
FS.ExtractTo = FS.ExtractTo or function(archivePath, dstPath)
    if not FS.Exists(dstPath) then FS.CreateDirectory(dstPath) end
    if FS.isWindows() then
        -- Deliberately NOT using the Expand-Archive cmdlet : Windows PowerShell 5.1's own
        -- Microsoft.PowerShell.Archive module tracks which paths it just wrote and does a
        -- Remove-Item cleanup pass over that list afterward. For archives containing certain
        -- non-ASCII entry names, that tracked list can drift from what actually landed on disk,
        -- and the cleanup throws "Cannot find path ... because it does not exist" for every
        -- affected file. Extracting directly via .NET's ZipFile API skips that extra bookkeeping
        -- layer entirely (no cleanup pass to go wrong), and normal .NET file I/O is Unicode-safe
        -- regardless of the OS's active ANSI codepage.
        local escapedArchive, escapedDst = archivePath:gsub("'", "''"), dstPath:gsub("'", "''")
        runPowerShell(string.format([[
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath '%s') { Remove-Item -LiteralPath '%s' -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory('%s', '%s')
]], escapedDst, escapedDst, escapedArchive, escapedDst))
    else
        os.execute("unzip -o " .. archivePath .. " -d " .. dstPath)
    end
end

---@param srcPath string
---@param destPath string
FS.Move = FS.Move or function(srcPath, destPath)
    if not FS.Exists(srcPath) or not FS.IsFile(srcPath) then return end
    FS.Copy(srcPath, destPath)
    FS.Remove(srcPath)
end

--- EXPERIMENTAL, not yet wired into any real code path : types a line of text into THIS
--- process's own console, as if a human had typed it and pressed Enter, then presses Enter.
--- Exists specifically for server console-only commands that have no Lua-callable equivalent
--- (confirmed directly with a BeamMP dev for "reloadmods" : it can reload Client/ folder contents
--- and serve them to newly-connecting players without a full process restart, but only via typing
--- it into the console, no MP.* API exists for it).
---
--- How: the short-lived PowerShell process this spawns (via the same runPowerShell helper used
--- elsewhere in this file, so no new os.execute pattern) is a direct child of the calling
--- BeamMP-Server.exe process, so it can find that parent's PID via WMI without Lua needing to
--- know its own process ID at all. It then calls the Win32 AttachConsole/WriteConsoleInput APIs
--- (via a small inline C# type) to attach to that SAME console and inject the text as real
--- key-event records, exactly like a human typing it, then detaches. This is a single short-lived
--- process that starts and exits on its own: no persistent/hidden background process, no
--- self-relaunching daemon.
---
--- Hard requirement: only works if BeamMP-Server.exe has a REAL attached console (launched
--- normally, double-clicked, or a plain `start`, not with its own stdin/stdout redirected to
--- pipes/files by a wrapper script, which replaces the real console this depends on).
---
--- NOT YET LIVE-TESTED against a real BeamMP-Server console. Confirm this actually reaches the
--- console and that the target command behaves as expected before relying on it anywhere real.
---@param command string
FS.SendConsoleCommand = FS.SendConsoleCommand or function(command)
    if not FS.isWindows() then
        LogError("FS.SendConsoleCommand is Windows-only (AttachConsole/WriteConsoleInput have no equivalent wired up here)")
        return
    end
    local escaped = command:gsub("'", "''")
    runPowerShell(string.format([[
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BJConsoleInput {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AttachConsole(uint dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteConsoleInput(IntPtr hConsoleInput, INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsWritten);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);

    const int STD_INPUT_HANDLE = -10;
    const ushort KEY_EVENT = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    public struct KEY_EVENT_RECORD {
        public bool bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char UnicodeChar;
        public uint dwControlKeyState;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }

    public static void SendLine(uint pid, string text) {
        // AttachConsole fails with ERROR_ACCESS_DENIED (5) if this process is already attached
        // to a console of its own (which it is here, inherited from being launched via
        // os.execute) -- has to detach from that first before it can attach to the target's.
        FreeConsole();
        if (!AttachConsole(pid)) throw new Exception("AttachConsole failed, error " + Marshal.GetLastWin32Error());
        try {
            IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
            string full = text + "\r\n";
            var records = new INPUT_RECORD[full.Length * 2];
            int i = 0;
            foreach (char c in full) {
                var down = new INPUT_RECORD();
                down.EventType = KEY_EVENT;
                down.KeyEvent.bKeyDown = true;
                down.KeyEvent.wRepeatCount = 1;
                down.KeyEvent.UnicodeChar = c;
                records[i++] = down;

                var up = new INPUT_RECORD();
                up.EventType = KEY_EVENT;
                up.KeyEvent.bKeyDown = false;
                up.KeyEvent.wRepeatCount = 1;
                up.KeyEvent.UnicodeChar = c;
                records[i++] = up;
            }
            uint written;
            WriteConsoleInput(h, records, (uint)records.Length, out written);
        } finally {
            FreeConsole();
        }
    }
}
'@ -ErrorAction Stop

$parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
[BJConsoleInput]::SendLine([uint32]$parentId, '%s')
]], escaped))
end
