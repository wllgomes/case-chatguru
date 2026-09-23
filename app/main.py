import os
import socket

from flask import Flask, jsonify

app = Flask(__name__)

APP_VERSION = os.environ.get("APP_VERSION", "0.0.0")
APP_ENV = os.environ.get("APP_ENV", "local")


@app.get("/health")
def health():
    """Health check simples, usado pelos probes do Kubernetes."""
    return jsonify(status="ok"), 200


@app.get("/healthz")
def healthz():
    """Alias comum de health check (algumas convenções usam /healthz)."""
    return health()


@app.get("/info")
def info():
    """Retorna metadados da aplicação: versão, ambiente e hostname do pod."""
    return jsonify(
        version=APP_VERSION,
        environment=APP_ENV,
        hostname=socket.gethostname(),
    ), 200


@app.get("/")
def root():
    return jsonify(message="case-chatguru API", docs="/info, /health"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)