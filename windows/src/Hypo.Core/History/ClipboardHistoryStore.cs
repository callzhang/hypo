using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Microsoft.Data.Sqlite;

namespace Hypo.Core.History;

public sealed record HistoryEntry
{
    public required ClipboardContent Content { get; init; }

    public required DateTimeOffset CopiedAt { get; init; }

    /// <summary>Which device it came from, or null when it was copied here.</summary>
    public string? SourceDeviceId { get; init; }

    public string? SourceDeviceName { get; init; }
}

/// <summary>
/// The clipboard history, kept in SQLite the way the macOS and Android clients
/// keep theirs.
/// </summary>
public sealed class ClipboardHistoryStore : IDisposable
{
    private readonly SqliteConnection _connection;
    private readonly int _capacity;

    /// <param name="path">The database file, or ":memory:" for a transient store.</param>
    /// <param name="capacity">How many entries to keep; the oldest go first.</param>
    public ClipboardHistoryStore(string path, int capacity = 500)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(capacity);

        _capacity = capacity;
        _connection = Open(path);
        CreateSchema();
    }

    /// <summary>
    /// Opens the file, rebuilding it if it is not a database we can read.
    ///
    /// <para>A clipboard tool that refuses to start because its history file is
    /// damaged has turned a cosmetic problem into a fatal one. The history is
    /// a convenience; syncing is the product. Losing it is survivable, and
    /// being unable to launch is not.</para>
    /// </summary>
    private static SqliteConnection Open(string path)
    {
        var connection = new SqliteConnection($"Data Source={path}");

        try
        {
            connection.Open();

            using var check = connection.CreateCommand();
            check.CommandText = "PRAGMA integrity_check;";
            var result = check.ExecuteScalar() as string;

            if (!string.Equals(result, "ok", StringComparison.Ordinal))
            {
                throw new SqliteException($"integrity_check returned '{result}'.", 11);
            }

            return connection;
        }
        catch (Exception ex) when (ex is SqliteException or InvalidOperationException)
        {
            // Dispose alone returns the connection to the pool and keeps the
            // file handle, so the delete below would be undone by the next open
            // handing back the very connection that just failed.
            SqliteConnection.ClearPool(connection);
            connection.Dispose();

            if (!string.Equals(path, ":memory:", StringComparison.Ordinal) && File.Exists(path))
            {
                File.Delete(path);
            }

            var rebuilt = new SqliteConnection($"Data Source={path}");
            rebuilt.Open();
            return rebuilt;
        }
    }

    private void CreateSchema()
    {
        using var command = _connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE IF NOT EXISTS history (
                hash               TEXT PRIMARY KEY,
                content_type       TEXT NOT NULL,
                data               BLOB NOT NULL,
                copied_at          TEXT NOT NULL,
                source_device_id   TEXT NULL,
                source_device_name TEXT NULL
            );
            CREATE INDEX IF NOT EXISTS history_copied_at ON history (copied_at DESC);
            """;
        command.ExecuteNonQuery();
    }

    /// <summary>
    /// Adds an entry, or moves existing content back to the top.
    ///
    /// <para>Re-copying something moves it rather than duplicating it, which is
    /// what the phone does. Matching that keeps the two histories legible side
    /// by side, which matters more than it sounds when diagnosing sync.</para>
    /// </summary>
    public void Add(HistoryEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);

        using var command = _connection.CreateCommand();
        command.CommandText = """
            INSERT INTO history (hash, content_type, data, copied_at, source_device_id, source_device_name)
            VALUES ($hash, $type, $data, $at, $deviceId, $deviceName)
            ON CONFLICT(hash) DO UPDATE SET
                copied_at          = excluded.copied_at,
                source_device_id   = excluded.source_device_id,
                source_device_name = excluded.source_device_name;
            """;
        command.Parameters.AddWithValue("$hash", Convert.ToHexString(entry.Content.Hash));
        command.Parameters.AddWithValue("$type", entry.Content.ContentType.ToString());
        command.Parameters.AddWithValue("$data", entry.Content.Data);
        command.Parameters.AddWithValue("$at", entry.CopiedAt.UtcDateTime.ToString("O"));
        command.Parameters.AddWithValue("$deviceId", (object?)entry.SourceDeviceId ?? DBNull.Value);
        command.Parameters.AddWithValue("$deviceName", (object?)entry.SourceDeviceName ?? DBNull.Value);
        command.ExecuteNonQuery();

        Trim();
    }

    public IReadOnlyList<HistoryEntry> Recent(int limit = 100)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(limit);

        using var command = _connection.CreateCommand();
        command.CommandText = """
            SELECT content_type, data, copied_at, source_device_id, source_device_name
            FROM history ORDER BY copied_at DESC LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$limit", limit);

        var entries = new List<HistoryEntry>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            entries.Add(new HistoryEntry
            {
                Content = new ClipboardContent
                {
                    ContentType = Enum.Parse<ContentType>(reader.GetString(0)),
                    Data = (byte[])reader[1],
                },
                CopiedAt = DateTimeOffset.Parse(reader.GetString(2), null, System.Globalization.DateTimeStyles.RoundtripKind),
                SourceDeviceId = reader.IsDBNull(3) ? null : reader.GetString(3),
                SourceDeviceName = reader.IsDBNull(4) ? null : reader.GetString(4),
            });
        }

        return entries;
    }

    private void Trim()
    {
        using var command = _connection.CreateCommand();
        command.CommandText = """
            DELETE FROM history WHERE hash IN (
                SELECT hash FROM history ORDER BY copied_at DESC LIMIT -1 OFFSET $capacity
            );
            """;
        command.Parameters.AddWithValue("$capacity", _capacity);
        command.ExecuteNonQuery();
    }

    public void Dispose() => _connection.Dispose();
}
