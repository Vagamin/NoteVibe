// Single-file portable launcher for NoteVibe (Windows).
//
// The Flutter app (exe + dlls + data/) is embedded as a zip resource.
// On start it is extracted once to %LOCALAPPDATA%\NoteVibe\app\<build id>
// (reused on later starts) and launched with --data-dir pointing to the
// "NoteVibe-Data" folder next to this file, so notes travel with the exe.
//
// Built by tools/portable/build_portable.ps1 with the csc.exe that ships
// with Windows (.NET Framework 4.x), so it runs on any Windows 10/11.
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            var asm = Assembly.GetExecutingAssembly();
            string buildId;
            using (var s = asm.GetManifestResourceStream("payload.id"))
            using (var r = new StreamReader(s)) buildId = r.ReadToEnd().Trim();

            var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NoteVibe", "app");
            var appDir = Path.Combine(root, buildId);
            var exe = Path.Combine(appDir, "notevibe.exe");

            if (!File.Exists(Path.Combine(appDir, ".complete")))
            {
                Directory.CreateDirectory(root);
                var tmp = appDir + ".tmp" + Process.GetCurrentProcess().Id;
                if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
                using (var s = asm.GetManifestResourceStream("payload.zip"))
                using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
                    zip.ExtractToDirectory(tmp);
                File.WriteAllText(Path.Combine(tmp, ".complete"), buildId);
                try
                {
                    if (Directory.Exists(appDir)) Directory.Delete(appDir, true);
                    Directory.Move(tmp, appDir);
                }
                catch (IOException)
                {
                    // Another instance finished extracting first.
                    if (Directory.Exists(tmp)) try { Directory.Delete(tmp, true); } catch { }
                }
                CleanupOldVersions(root, buildId);
            }

            var dataDir = PickDataDir();
            // Lets the app find its data even when started directly (taskbar pin, shortcut).
            File.WriteAllText(Path.Combine(appDir, "portable.json"),
                "{\"dataDir\":\"" + Json(dataDir) + "\",\"launcher\":\"" + Json(Assembly.GetExecutingAssembly().Location) + "\"}");
            var psi = new ProcessStartInfo(exe);
            psi.Arguments = "--data-dir \"" + dataDir.TrimEnd('\\') + "\"";
            psi.WorkingDirectory = appDir;
            psi.UseShellExecute = false;
            Process.Start(psi);
            return 0;
        }
        catch (Exception e)
        {
            MessageBox.Show("Не удалось запустить NoteVibe:\n\n" + e.Message, "NoteVibe",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    // Notes live next to the launcher. If that folder is read-only
    // (e.g. Program Files or a write-protected stick) fall back to AppData.
    static string PickDataDir()
    {
        var here = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        var dir = Path.Combine(here, "NoteVibe-Data");
        try
        {
            Directory.CreateDirectory(dir);
            var probe = Path.Combine(dir, ".write-test");
            File.WriteAllText(probe, "ok");
            File.Delete(probe);
            return dir;
        }
        catch
        {
            var fallback = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NoteVibe", "data");
            Directory.CreateDirectory(fallback);
            return fallback;
        }
    }

    static string Json(string s)
    {
        return s.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    static void CleanupOldVersions(string root, string keep)
    {
        foreach (var d in Directory.GetDirectories(root))
        {
            if (string.Equals(Path.GetFileName(d), keep, StringComparison.OrdinalIgnoreCase)) continue;
            try { Directory.Delete(d, true); } catch { /* in use by a running instance */ }
        }
    }
}
