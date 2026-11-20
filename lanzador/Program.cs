// PCCare.exe: lanzador de PC Care.
//
// Que hace (y nada mas):
//   1. Busca PCCare.ps1 junto a este programa.
//   2. Quita la marca "descargado de internet" de los archivos de PC Care (igual que Unblock-File).
//   3. Abre PowerShell sin ventana de consola con PCCare.ps1 y le pasa los mismos argumentos.
//   4. Espera. Si PC Care termina con error, lo muestra en un cuadro y lo anota en
//      %LOCALAPPDATA%\PCCare\lanzador.log (antes ese texto salia en la consola).
//
// No abre conexiones de red, no descarga nada ni toca archivos fuera de la carpeta de PC Care
// (salvo el registro lanzador.log). El manifiesto pide permisos de administrador una sola vez.
//
// Escrito en C# 5 para compilarse con el csc.exe que trae Windows (.NET Framework 4), sin instalar nada.
// Variable de entorno PCCARE_LANZADOR_SIN_CUADROS=1: no muestra cuadros (la usan las pruebas de CI).

using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace Novaltek.PCCare
{
    internal static class Lanzador
    {
        private const string UrlIssues = "https://github.com/marcoadtup-cmd/PCCare/issues";
        private const int MaxErrorChars = 3000;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string texto, string titulo, uint tipo);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool DeleteFileW(string ruta);

        private static int Main(string[] args)
        {
            string carpeta = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            string script = Path.Combine(carpeta, "PCCare.ps1");
            bool en = EsIngles();

            if (!File.Exists(script))
            {
                string msg = en
                    ? "PCCare.ps1 was not found next to PCCare.exe.\n\nExtract the WHOLE ZIP folder and open PC Care again."
                    : "No se encontró PCCare.ps1 junto a PCCare.exe.\n\nExtrae TODA la carpeta del ZIP y vuelve a abrir PC Care.";
                Registrar(2, msg);
                Avisar(msg);
                return 2;
            }

            QuitarBloqueo(carpeta);

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell)) powershell = "powershell.exe";

            StringBuilder linea = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -File ");
            linea.Append(Comillas(script));
            foreach (string a in args) linea.Append(' ').Append(Comillas(a));

            ProcessStartInfo info = new ProcessStartInfo(powershell, linea.ToString());
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WorkingDirectory = carpeta;
            info.RedirectStandardError = true;
            try { info.StandardErrorEncoding = Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.OEMCodePage); }
            catch (Exception) { }

            StringBuilder errores = new StringBuilder();
            int codigo;
            try
            {
                using (Process p = new Process())
                {
                    p.StartInfo = info;
                    p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
                    {
                        if (e.Data == null) return;
                        lock (errores)
                        {
                            errores.AppendLine(e.Data);
                            if (errores.Length > MaxErrorChars * 2) errores.Remove(0, errores.Length - MaxErrorChars);
                        }
                    };
                    p.Start();
                    p.BeginErrorReadLine();
                    p.WaitForExit();
                    codigo = p.ExitCode;
                }
            }
            catch (Exception ex)
            {
                string msg = (en ? "PowerShell could not be started: " : "No se pudo iniciar PowerShell: ") + ex.Message;
                Registrar(1, msg);
                Avisar(msg);
                return 1;
            }

            if (codigo != 0)
            {
                string detalle;
                lock (errores)
                {
                    detalle = errores.ToString().Trim();
                    if (detalle.Length > MaxErrorChars) detalle = detalle.Substring(detalle.Length - MaxErrorChars);
                }
                Registrar(codigo, detalle);
                string cabecera = en
                    ? "PC Care ended with an error (code " + codigo + ")."
                    : "PC Care terminó con un error (código " + codigo + ").";
                string pie = en
                    ? "Copy this message and open an Issue on GitHub:\n" + UrlIssues + "\n\nIt is also saved in:\n" + RutaLog()
                    : "Copia este mensaje y abre un Issue en GitHub:\n" + UrlIssues + "\n\nTambién queda registrado en:\n" + RutaLog();
                Avisar(cabecera + (detalle.Length > 0 ? "\n\n" + detalle : "") + "\n\n" + pie);
            }
            return codigo;
        }

        // Argumento con comillas segun las reglas de CommandLineToArgvW (espacios, comillas y barras finales)
        private static string Comillas(string a)
        {
            if (a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return a;
            StringBuilder sb = new StringBuilder("\"");
            int barras = 0;
            foreach (char c in a)
            {
                if (c == '\\') { barras++; continue; }
                if (c == '"') { sb.Append('\\', barras * 2 + 1); sb.Append('"'); }
                else { sb.Append('\\', barras); sb.Append(c); }
                barras = 0;
            }
            sb.Append('\\', barras * 2);
            sb.Append('"');
            return sb.ToString();
        }

        // Quita la marca de "descargado de internet" (flujo Zone.Identifier) de los scripts de PC Care
        private static void QuitarBloqueo(string carpeta)
        {
            try
            {
                foreach (string patron in new string[] { "*.ps1", "*.cmd" })
                    foreach (string f in Directory.GetFiles(carpeta, patron)) DeleteFileW(f + ":Zone.Identifier");
                string modulos = Path.Combine(carpeta, "modulos");
                if (Directory.Exists(modulos))
                    foreach (string f in Directory.GetFiles(modulos, "*.ps1", SearchOption.AllDirectories)) DeleteFileW(f + ":Zone.Identifier");
            }
            catch (Exception) { }
        }

        private static bool EsIngles()
        {
            try
            {
                string ruta = Path.Combine(CarpetaDatos(), "config.json");
                if (File.Exists(ruta))
                {
                    Match m = Regex.Match(File.ReadAllText(ruta, Encoding.UTF8), "\"Idioma\"\\s*:\\s*\"(es|en)\"");
                    if (m.Success) return m.Groups[1].Value == "en";
                }
            }
            catch (Exception) { }
            return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName != "es";
        }

        private static string CarpetaDatos()
        {
            string baseDir = Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if (string.IsNullOrEmpty(baseDir)) baseDir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(baseDir, "PCCare");
        }

        private static string RutaLog()
        {
            return Path.Combine(CarpetaDatos(), "lanzador.log");
        }

        private static void Registrar(int codigo, string detalle)
        {
            try
            {
                Directory.CreateDirectory(CarpetaDatos());
                string ruta = RutaLog();
                if (File.Exists(ruta) && new FileInfo(ruta).Length > 200 * 1024) File.Delete(ruta);
                string version = typeof(Lanzador).Assembly.GetName().Version.ToString();
                File.AppendAllText(ruta,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) +
                    " | PCCare.exe " + version + " | código " + codigo + "\r\n" + detalle + "\r\n\r\n",
                    new UTF8Encoding(true));
            }
            catch (Exception) { }
        }

        private static void Avisar(string texto)
        {
            if (Environment.GetEnvironmentVariable("PCCARE_LANZADOR_SIN_CUADROS") == "1") return;
            MessageBoxW(IntPtr.Zero, texto, "PC Care", 0x10);
        }
    }
}
