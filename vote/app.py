from flask import Flask, render_template, request, make_response, g
from redis import Redis
from datadog import DogStatsd
import os
import socket
import random
import json
import logging
import os
from datadog import DogStatsd



# DogStatsD client – use DD_AGENT_HOST if available, fallback to localhost
statsd = DogStatsd(
    host=os.getenv("DD_AGENT_HOST","127.0.0.1"),
    port=int(os.getenv("DD_DOGSTATSD_PORT","8125"))
)

option_a = os.getenv('OPTION_A', "Cats")
option_b = os.getenv('OPTION_B', "Dogs")
hostname = socket.gethostname()

app = Flask(__name__)

# Configure logging format for Datadog correlation
FORMAT = ('%(asctime)s %(levelname)s [%(name)s] [%(filename)s:%(lineno)d] '
          '[dd.service=%(dd.service)s dd.env=%(dd.env)s dd.version=%(dd.version)s dd.trace_id=%(dd.trace_id)s dd.span_id=%(dd.span_id)s] '
          '- %(message)s')

# Set up logging to work with both development and Gunicorn
if __name__ != "__main__":
    # Running under Gunicorn - configure the root logger and app logger
    gunicorn_logger = logging.getLogger('gunicorn.error')
    app.logger.handlers = gunicorn_logger.handlers
    app.logger.setLevel(gunicorn_logger.level)
    
    # Apply our format to all existing handlers
    formatter = logging.Formatter(FORMAT)
    for handler in app.logger.handlers:
        handler.setFormatter(formatter)
else:
    # Running in development - use basicConfig
    logging.basicConfig(format=FORMAT, level=logging.INFO)
    app.logger.setLevel(logging.INFO)

# Log application startup
app.logger.info('Voting app starting up on hostname: %s', hostname)
app.logger.info('Vote options configured: %s vs %s', option_a, option_b)

def get_redis():
    if not hasattr(g, 'redis'):
        g.redis = Redis(host="redis", db=0, socket_timeout=5)
        app.logger.info('Established Redis connection')
    return g.redis

@app.route("/", methods=['POST','GET'])
def hello():
    app.logger.info('Processing request from %s', request.remote_addr)
    
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = hex(random.getrandbits(64))[2:-1]
        app.logger.info('Generated new voter_id: %s', voter_id)

    vote = None
    
    if request.method == 'POST':
        redis = get_redis()
        vote = request.form['vote']
        app.logger.info('Received vote for %s from voter %s', vote, voter_id)
        data = json.dumps({'voter_id': voter_id, 'vote': vote})
        redis.rpush('votes', data)
        app.logger.info('Successfully stored vote in Redis')

        # 🔥 custom metric to Datadog
        statsd.increment(
            "voting_app.vote.submitted",
            tags=[f"option:{vote}", "service:vote", "env:demo"]
        )
    else:
        app.logger.info('Displaying voting page for voter %s', voter_id)

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
    ))
    resp.set_cookie('voter_id', voter_id)
    app.logger.info('Sending response to voter %s', voter_id)
    return resp


if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80, debug=True, threaded=True)
