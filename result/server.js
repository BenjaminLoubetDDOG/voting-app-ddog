var express = require('express'),
    async = require('async'),
    { Pool } = require('pg'),
    cookieParser = require('cookie-parser'),
    app = express(),
    server = require('http').Server(app),
    io = require('socket.io')(server),
    path = require('path');

var port = process.env.PORT || 4000;

// Winston logger configuration for Datadog correlation
const winston = require('winston');

// Custom format for Datadog correlation
const datadogFormat = winston.format.combine(
  winston.format.timestamp(),
  winston.format.printf(({ timestamp, level, message, service = 'result', filename = 'server.js' }) => {
    // Try to get trace info from Datadog APM if available
    let traceId = 'N/A';
    let spanId = 'N/A';
    
    try {
      // This will be populated by Datadog APM when SSI is active
      if (global.tracer && global.tracer.scope) {
        const span = global.tracer.scope().active();
        if (span) {
          traceId = span.context().toTraceId();
          spanId = span.context().toSpanId();
        }
      }
    } catch (e) {
      // Fallback to N/A if APM not available
    }
    
    return `${timestamp} ${level.toUpperCase()} [${service}] [${filename}] [dd.service=${service} dd.env=demo dd.version=1.0.0 dd.trace_id=${traceId} dd.span_id=${spanId}] - ${message}`;
  })
);

// Create winston logger
const logger = winston.createLogger({
  level: 'info',
  format: datadogFormat,
  transports: [
    new winston.transports.Console({
      handleExceptions: true,
      handleRejections: true
    })
  ],
  exitOnError: false
});

// Helper functions for easier logging
const logInfo = (message, meta = {}) => logger.info(message, meta);
const logError = (message, meta = {}) => logger.error(message, meta);
const logWarn = (message, meta = {}) => logger.warn(message, meta);
const logDebug = (message, meta = {}) => logger.debug(message, meta);

logInfo('Result app starting up...');

io.on('connection', function (socket) {
  logInfo('New socket connection established', { 
    clientIP: socket.handshake.address,
    socketId: socket.id,
    userAgent: socket.handshake.headers['user-agent']
  });
  
  socket.emit('message', { text : 'Welcome!' });

  socket.on('subscribe', function (data) {
    logInfo('Socket subscribed to channel', { 
      channel: data.channel,
      socketId: socket.id
    });
    socket.join(data.channel);
  });
  
  socket.on('disconnect', function() {
    logInfo('Socket disconnected', { socketId: socket.id });
  });
});

var pool = new Pool({
  connectionString: 'postgres://postgres:postgres@db/postgres'
});

async.retry(
  {times: 1000, interval: 1000},
  function(callback) {
    pool.connect(function(err, client, done) {
      if (err) {
        logError("Waiting for database connection...");
      }
      callback(err, client);
    });
  },
  function(err, client) {
    if (err) {
      logError("Failed to connect to database after retries");
      return;
    }
    logInfo("Successfully connected to database");
    getVotes(client);
  }
);

function getVotes(client) {
  client.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [], function(err, result) {
    if (err) {
      logError("Database query failed", { 
        error: err.message,
        query: 'SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote'
      });
    } else {
      var votes = collectVotesFromResult(result);
      logInfo('Vote query completed successfully', { 
        votesA: votes.a,
        votesB: votes.b,
        totalVotes: votes.a + votes.b,
        queryDuration: 'fast'
      });
      io.sockets.emit("scores", JSON.stringify(votes));
    }

    setTimeout(function() {getVotes(client) }, 1000);
  });
}

function collectVotesFromResult(result) {
  var votes = {a: 0, b: 0};

  result.rows.forEach(function (row) {
    votes[row.vote] = parseInt(row.count);
  });

  return votes;
}

app.use(cookieParser());
app.use(express.urlencoded());
app.use(express.json()); // Add JSON parsing for API endpoints
app.use(express.static(__dirname + '/views'));

// API endpoint for refreshing data (user action for RUM/APM correlation)
app.post('/api/refresh', function (req, res) {
  const startTime = Date.now();
  logInfo('Manual refresh requested', { 
    method: req.method,
    url: req.url,
    clientIP: req.ip,
    userAgent: req.get('User-Agent')
  });
  
  // Simulate some processing time
  setTimeout(() => {
    pool.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [], function(err, result) {
      const duration = Date.now() - startTime;
      
      if (err) {
        logError("Manual refresh query failed", { 
          error: err.message,
          duration: duration + 'ms',
          clientIP: req.ip
        });
        res.status(500).json({ error: 'Database error' });
      } else {
        var votes = collectVotesFromResult(result);
        logInfo('Manual refresh completed successfully', { 
          votesA: votes.a,
          votesB: votes.b,
          totalVotes: votes.a + votes.b,
          duration: duration + 'ms',
          clientIP: req.ip
        });
        
        // Emit to all connected sockets
        io.sockets.emit("scores", JSON.stringify(votes));
        
        res.json({ 
          success: true, 
          votes: votes,
          timestamp: new Date().toISOString()
        });
      }
    });
  }, 100);
});

// API endpoint for getting current stats (user action for RUM/APM correlation)
app.get('/api/stats', function (req, res) {
  const startTime = Date.now();
  logInfo('Stats API requested', { 
    method: req.method,
    url: req.url,
    clientIP: req.ip,
    userAgent: req.get('User-Agent')
  });
  
  pool.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [], function(err, result) {
    const duration = Date.now() - startTime;
    
    if (err) {
      logError("Stats query failed", { 
        error: err.message,
        duration: duration + 'ms',
        clientIP: req.ip
      });
      res.status(500).json({ error: 'Database error' });
    } else {
      var votes = collectVotesFromResult(result);
      var total = votes.a + votes.b;
      var stats = {
        votes: votes,
        total: total,
        percentages: {
          a: total > 0 ? Math.round((votes.a / total) * 100) : 50,
          b: total > 0 ? Math.round((votes.b / total) * 100) : 50
        },
        timestamp: new Date().toISOString()
      };
      
      logInfo('Stats API completed successfully', { 
        totalVotes: total,
        duration: duration + 'ms',
        clientIP: req.ip,
        percentageA: stats.percentages.a,
        percentageB: stats.percentages.b
      });
      res.json(stats);
    }
  });
});

// API endpoint for exporting results (user action for RUM/APM correlation)
app.get('/api/export', function (req, res) {
  const startTime = Date.now();
  logInfo('Export requested', { 
    method: req.method,
    url: req.url,
    clientIP: req.ip,
    userAgent: req.get('User-Agent')
  });
  
  pool.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [], function(err, result) {
    const duration = Date.now() - startTime;
    
    if (err) {
      logError("Export query failed", { 
        error: err.message,
        duration: duration + 'ms',
        clientIP: req.ip
      });
      res.status(500).json({ error: 'Database error' });
    } else {
      var votes = collectVotesFromResult(result);
      var exportData = {
        export_date: new Date().toISOString(),
        total_votes: votes.a + votes.b,
        results: {
          cats: votes.a,
          dogs: votes.b
        },
        winner: votes.a > votes.b ? 'cats' : votes.b > votes.a ? 'dogs' : 'tie'
      };
      
      logInfo('Export completed successfully', { 
        totalVotes: exportData.total_votes,
        winner: exportData.winner,
        duration: duration + 'ms',
        clientIP: req.ip,
        fileSize: JSON.stringify(exportData).length + ' bytes'
      });
      
      res.setHeader('Content-Type', 'application/json');
      res.setHeader('Content-Disposition', 'attachment; filename="voting-results.json"');
      res.json(exportData);
    }
  });
});

app.get('/', function (req, res) {
  logInfo('Homepage requested', { 
    method: req.method,
    url: req.url,
    clientIP: req.ip,
    userAgent: req.get('User-Agent')
  });
  res.sendFile(path.resolve(__dirname + '/views/index.html'));
});

server.listen(port, function () {
  var actualPort = server.address().port;
  logInfo('Result app server started successfully', { 
    port: actualPort,
    env: process.env.NODE_ENV || 'development',
    nodeVersion: process.version,
    platform: process.platform
  });
});
