using System;
using System.Data.Common;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using Newtonsoft.Json;
using Npgsql;
using StackExchange.Redis;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Worker
{
    public class Program
    {
        private static readonly ILogger _logger;

        static Program()
        {
            // Follow documentation pattern for log correlation
            var host = Host.CreateDefaultBuilder()
                .ConfigureLogging(logging =>
                {
                    logging.ClearProviders();
                    logging.AddConsole(opts =>
                    {
                        opts.IncludeScopes = true; // must include scopes so that correlation identifiers are added
                        opts.FormatterName = "json";
                    });
                })
                .Build();
            
            _logger = host.Services.GetRequiredService<ILogger<Program>>();
        }

        public static int Main(string[] args)
        {
            _logger.LogInformation("Worker service starting up");
            
            try
            {
                var pgsql = OpenDbConnection("Server=db;Username=postgres;Password=postgres;");
                var redisConn = OpenRedisConnection("redis");
                var redis = redisConn.GetDatabase();
                
                _logger.LogInformation("Successfully established connections to database and Redis");

                // Keep alive is not implemented in Npgsql yet. This workaround was recommended:
                // https://github.com/npgsql/npgsql/issues/1214#issuecomment-235828359
                var keepAliveCommand = pgsql.CreateCommand();
                keepAliveCommand.CommandText = "SELECT 1";

                var definition = new { vote = "", voter_id = "" };
                while (true)
                {
                    // Slow down to prevent CPU spike, only query each 100ms
                    Thread.Sleep(100);

                    // Reconnect redis if down
                    if (redisConn == null || !redisConn.IsConnected) {
                        _logger.LogWarning("Redis connection lost, attempting to reconnect");
                        redisConn = OpenRedisConnection("redis");
                        redis = redisConn.GetDatabase();
                    }
                    string json = redis.ListLeftPopAsync("votes").Result;
                    if (json != null)
                    {
                        var vote = JsonConvert.DeserializeAnonymousType(json, definition);
                        _logger.LogInformation("Processing vote for {VoteType} by {VoterId}", 
                            vote.vote, vote.voter_id);
                        
                        // Reconnect DB if down
                        if (!pgsql.State.Equals(System.Data.ConnectionState.Open))
                        {
                            _logger.LogWarning("Database connection lost, attempting to reconnect");
                            pgsql = OpenDbConnection("Server=db;Username=postgres;Password=postgres;");
                        }
                        else
                        { // Normal +1 vote requested
                            var startTime = DateTime.UtcNow;
                            UpdateVote(pgsql, vote.voter_id, vote.vote);
                            var duration = (DateTime.UtcNow - startTime).TotalMilliseconds;
                            _logger.LogInformation("Successfully stored vote for {VoteType} by {VoterId} in {Duration}ms", 
                                vote.vote, vote.voter_id, duration);
                        }
                    }
                    else
                    {
                        keepAliveCommand.ExecuteNonQuery();
                    }
                }
            }
            catch (Exception ex)
            {
                _logger.LogCritical(ex, "Worker service encountered fatal error: {ErrorMessage}", ex.Message);
                return 1;
            }
            finally
            {
                _logger.LogInformation("Worker service shutting down");
            }
        }

        private static NpgsqlConnection OpenDbConnection(string connectionString)
        {
            NpgsqlConnection connection;
            var attempts = 0;

            while (true)
            {
                try
                {
                    attempts++;
                    _logger.LogDebug("Attempting to connect to database (attempt {Attempt})", attempts);
                    connection = new NpgsqlConnection(connectionString);
                    connection.Open();
                    break;
                }
                catch (SocketException ex)
                {
                    _logger.LogWarning("Database connection failed (attempt {Attempt}): {ErrorMessage}", 
                        attempts, ex.Message);
                    Thread.Sleep(1000);
                }
                catch (DbException ex)
                {
                    _logger.LogWarning("Database connection failed (attempt {Attempt}): {ErrorMessage}", 
                        attempts, ex.Message);
                    Thread.Sleep(1000);
                }
            }

            _logger.LogInformation("Successfully connected to database after {Attempts} attempts", attempts);

            var command = connection.CreateCommand();
            command.CommandText = @"CREATE TABLE IF NOT EXISTS votes (
                                        id VARCHAR(255) NOT NULL UNIQUE,
                                        vote VARCHAR(255) NOT NULL
                                    )";
            command.ExecuteNonQuery();

            return connection;
        }

        private static ConnectionMultiplexer OpenRedisConnection(string hostname)
        {
            // Use IP address to workaround https://github.com/StackExchange/StackExchange.Redis/issues/410
            var ipAddress = GetIp(hostname);
            _logger.LogDebug("Resolved Redis hostname {Hostname} to IP {IpAddress}", hostname, ipAddress);

            var attempts = 0;
            while (true)
            {
                try
                {
                    attempts++;
                    _logger.LogDebug("Attempting to connect to Redis at {IpAddress} (attempt {Attempt})", 
                        ipAddress, attempts);
                    var connection = ConnectionMultiplexer.Connect(ipAddress);
                    _logger.LogInformation("Successfully connected to Redis at {IpAddress} after {Attempts} attempts", 
                        ipAddress, attempts);
                    return connection;
                }
                catch (RedisConnectionException ex)
                {
                    _logger.LogWarning("Redis connection failed (attempt {Attempt}): {ErrorMessage}", 
                        attempts, ex.Message);
                    Thread.Sleep(1000);
                }
            }
        }

        private static string GetIp(string hostname)
            => Dns.GetHostEntryAsync(hostname)
                .Result
                .AddressList
                .First(a => a.AddressFamily == AddressFamily.InterNetwork)
                .ToString();

        private static void UpdateVote(NpgsqlConnection connection, string voterId, string vote)
        {
            var command = connection.CreateCommand();
            try
            {
                // Try to insert new vote
                command.CommandText = "INSERT INTO votes (id, vote) VALUES (@id, @vote)";
                command.Parameters.AddWithValue("@id", voterId);
                command.Parameters.AddWithValue("@vote", vote);
                command.ExecuteNonQuery();
                _logger.LogDebug("Inserted new vote for voter {VoterId}", voterId);
            }
            catch (DbException ex)
            {
                // Voter already exists, update their vote
                _logger.LogDebug("Voter {VoterId} already exists, updating vote: {ErrorMessage}", 
                    voterId, ex.Message);
                command.CommandText = "UPDATE votes SET vote = @vote WHERE id = @id";
                command.ExecuteNonQuery();
                _logger.LogDebug("Updated existing vote for voter {VoterId}", voterId);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to store vote for voter {VoterId}: {ErrorMessage}", 
                    voterId, ex.Message);
                throw;
            }
            finally
            {
                command.Dispose();
            }
        }
    }
}