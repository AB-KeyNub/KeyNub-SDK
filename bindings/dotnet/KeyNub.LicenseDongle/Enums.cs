namespace KeyNub.LicenseDongle
{
    /// <summary>
    /// Scope for app-data envelope encryption (<see cref="Session.AppEncrypt"/>).
    /// Mirrors <c>licd_scope</c>.
    /// </summary>
    public enum Scope
    {
        /// <summary>Only this physical dongle can decrypt (node-locking).</summary>
        Device = 0,
        /// <summary>Any dongle from the same developer batch can decrypt.</summary>
        Developer = 1,
    }

    /// <summary>Severity of a diagnostic log message. Mirrors <c>licd_log_level</c>.</summary>
    public enum LogLevel
    {
        /// <summary>An error.</summary>
        Error = 0,
        /// <summary>A warning.</summary>
        Warn = 1,
        /// <summary>Informational.</summary>
        Info = 2,
        /// <summary>Verbose debugging detail.</summary>
        Debug = 3,
    }
}
