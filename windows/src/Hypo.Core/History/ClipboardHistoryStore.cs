using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Core.Transport;
using Microsoft.Data.Sqlite;

namespace Hypo.Core.History;

public sealed record HistoryEntry
{
    public required ClipboardContent Content { get; init; }

    public required DateTimeOffset CopiedAt { get; init; }

    /// <summary>Which device it came from, or null when it was copied here.</summary>
    public string? SourceDeviceId { get; init; }

    public string? SourceDeviceName { get; init; }

    /// <summary>
    /// Which channel carried it, or null when it was copied on this machine.
    ///
    /// <para>Worth keeping rather than deriving: "did that arrive over the LAN or
    /// go all the way to the relay and back?" is the first question about slow
    /// syncing, and by the time it is asked the connection has usually
    /// changed.</para>
    /// </summary>
    public TransportOrigin? Origin { get; init; }

    /// <summary>Whether it is held at the top of the list.</summary>
    public bool Pinned { get; init; }
}

/// <summary>
/// The clipboard history, kept in SQLite the way the macOS and Android clients
/// keep theirs.
/// </summary>
public sealed class ClipboardHistoryStore : IDisposable
{
    private readonly SqliteConnection _connection;
    private int _capacity;

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
                source_device_name TEXT NULL,
                metadata           TEXT NULL,
                origin             TEXT NULL,
                pinned             INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS history_copied_at ON history (copied_at DESC);
            """;
        command.ExecuteNonQuery();

        AddColumnIfMissing("metadata", "TEXT NULL");
        AddColumnIfMissing("origin", "TEXT NULL");
        AddColumnIfMissing("pinned", "INTEGER NOT NULL DEFAULT 0");
    }

    /// <summary>
    /// Adds a column to a database created before it existed.
    ///
    /// <para>An existing history is a user's data, not a cache. Recreating the
    /// table would silently throw away everything they had copied, which is a
    /// worse outcome than the missing feature.</para>
    /// </summary>
    private void AddColumnIfMissing(string name, string definition)
    {
        using var columns = _connection.CreateCommand();
        columns.CommandText = "SELECT COUNT(*) FROM pragma_table_info('history') WHERE name = $name;";
        columns.Parameters.AddWithValue("$name", name);

        if (Convert.ToInt64(columns.ExecuteScalar()) > 0)
        {
            return;
        }

        using var alter = _connection.CreateCommand();
        alter.CommandText = $"ALTER TABLE history ADD COLUMN {name} {definition};";
        alter.ExecuteNonQuery();
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
            INSERT INTO history (
                hash, content_type, data, copied_at,
                source_device_id, source_device_name, metadata, origin, pinned)
            VALUES ($hash, $type, $data, $at, $deviceId, $deviceName, $metadata, $origin, $pinned)
            ON CONFLICT(hash) DO UPDATE SET
                copied_at          = excluded.copied_at,
                source_device_id   = excluded.source_device_id,
                source_device_name = excluded.source_device_name,
                metadata           = excluded.metadata,
                origin             = excluded.origin,
                -- Re-copying something pinned must not unpin it. The insert
                -- cannot know: it is the copy path, and nothing there has any
                -- opinion about pinning.
                pinned             = history.pinned;
            """;
        command.Parameters.AddWithValue("$hash", Convert.ToHexString(entry.Content.Hash));
        command.Parameters.AddWithValue("$type", entry.Content.ContentType.ToString());
        command.Parameters.AddWithValue("$data", entry.Content.Data);
        command.Parameters.AddWithValue("$at", entry.CopiedAt.UtcDateTime.ToString("O"));
        command.Parameters.AddWithValue("$deviceId", (object?)entry.SourceDeviceId ?? DBNull.Value);
        command.Parameters.AddWithValue("$deviceName", (object?)entry.SourceDeviceName ?? DBNull.Value);
        command.Parameters.AddWithValue(
            "$metadata",
            entry.Content.Metadata is { Count: > 0 } metadata
                ? System.Text.Json.JsonSerializer.Serialize(metadata)
                : (object)DBNull.Value);
        command.Parameters.AddWithValue(
            "$origin", entry.Origin is { } origin ? origin.ToString() : (object)DBNull.Value);
        command.Parameters.AddWithValue("$pinned", entry.Pinned ? 1 : 0);
        command.ExecuteNonQuery();

        Trim();
    }

    public IReadOnlyList<HistoryEntry> Recent(int limit = 100)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(limit);

        using var command = _connection.CreateCommand();
        command.CommandText = """
            SELECT content_type, data, copied_at, source_device_id, source_device_name,
                   metadata, origin, pinned, hash
            FROM history ORDER BY pinned DESC, copied_at DESC LIMIT $limit;
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
                    Metadata = reader.IsDBNull(5)
                        ? null
                        : System.Text.Json.JsonSerializer
                            .Deserialize<Dictionary<string, string>>(reader.GetString(5)),
                },
                CopiedAt = DateTimeOffset.Parse(reader.GetString(2), null, System.Globalization.DateTimeStyles.RoundtripKind),
                SourceDeviceId = reader.IsDBNull(3) ? null : reader.GetString(3),
                SourceDeviceName = reader.IsDBNull(4) ? null : reader.GetString(4),
                Origin = reader.IsDBNull(6) ? null : Enum.Parse<TransportOrigin>(reader.GetString(6)),
                Pinned = !reader.IsDBNull(7) && reader.GetInt64(7) != 0,
            });
        }

        return entries;
    }

    /// <summary>
    /// How many entries to keep. Lowering it takes effect at once.
    ///
    /// <para>Someone who has just decided they want less of their clipboard kept
    /// on disk means now, not from the next copy onwards.</para>
    /// </summary>
    /// <summary>
    /// Pins or unpins an entry, which is identified by its content.
    ///
    /// <para>By hash rather than a row id, because the hash is what the table is
    /// keyed on: re-copying something moves it rather than duplicating it, so
    /// the pin has to follow the content and not a position.</para>
    /// </summary>
    public bool SetPinned(ClipboardContent content, bool pinned)
    {
        ArgumentNullException.ThrowIfNull(content);

        using var command = _connection.CreateCommand();
        command.CommandText = "UPDATE history SET pinned = $pinned WHERE hash = $hash;";
        command.Parameters.AddWithValue("$pinned", pinned ? 1 : 0);
        command.Parameters.AddWithValue("$hash", Convert.ToHexString(content.Hash));

        return command.ExecuteNonQuery() > 0;
    }

    public int Capacity
    {
        get => _capacity;
        set
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(value);

            _capacity = value;
            Trim();
        }
    }

    /// <summary>
    /// Forgets everything.
    ///
    /// <para>VACUUM as well as DELETE: a clipboard history holds whatever was
    /// copied, and a file that still contains the rows in its free pages has not
    /// honoured what was asked.</para>
    /// </summary>
    public void Clear()
    {
        using (var command = _connection.CreateCommand())
        {
            command.CommandText = "DELETE FROM history;";
            command.ExecuteNonQuery();
        }

        using var vacuum = _connection.CreateCommand();
        vacuum.CommandText = "VACUUM;";
        vacuum.ExecuteNonQuery();
    }

    private void Trim()
    {
        using var command = _connection.CreateCommand();
        command.CommandText = """
            DELETE FROM history WHERE hash IN (
                SELECT hash FROM history
                -- Pinned first, so the entries someone asked to keep are the last
                -- to fall off the end rather than the first.
                ORDER BY pinned DESC, copied_at DESC LIMIT -1 OFFSET $capacity
            );
            """;
        command.Parameters.AddWithValue("$capacity", _capacity);
        command.ExecuteNonQuery();
    }

    /// <summary>
    /// Closes the database and releases the file handle.
    ///
    /// <para>Clearing the pool is not optional. Dispose alone hands the
    /// connection back to the pool, which keeps the file open; on Windows the
    /// file then cannot be deleted, moved or replaced, so anything that closes
    /// the store to tidy up its file fails with a sharing violation. Unix
    /// permits deleting an open file, which is why this only ever shows up on
    /// the platform the client actually ships to.</para>
    /// </summary>
    public void Dispose()
    {
        SqliteConnection.ClearPool(_connection);
        _connection.Dispose();
    }
}
