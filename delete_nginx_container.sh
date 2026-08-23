#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status
FLASK_CONTAINER_NAME="tsync_flask"
NGINX_PROXY_CONTAINER_NAME="nginx_proxy"

read -p "Make sure you are placed (with cd commands) in the main directory with all the python, HTML, JS files!! Are you in the correct directory? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "-*-* Start creating docker and flask files -*-*"
else
    echo "Stopped by the user."
    exit 0
fi

echo "Remove old configurations files if exists"
rm -f -- docker-compose.yml
rm -f -- Dockerfile
rm -f -- nginx.conf
rm -f -- requirements.txt

echo "-*-* Create docker compose yml file *-*-"
cat >docker-compose.yml <<EOL
services:
  tsync_app:
    build: .
    container_name: tsync_flask
    restart: always
    environment:
      - MONGO_URI=mongodb://mongodb_docker_container:27017/
      - S3_ENDPOINT_URL=http://minio-docker-container:9000
      - S3_EXTERNAL_URL=http://localhost:9000
    volumes:
      - ./bot_cache:/app/bot_cache
      - ./sessions:/app/sessions
    networks:
      - docker_default

  nginx_tsync:
    image: nginx:latest
    container_name: nginx_proxy
    #restart: always
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./static:/app/static:ro
    depends_on:
      - tsync_app
    networks:
      - docker_default

networks:
  docker_default:
    external: true
    name: docker_default
EOL

echo "Create Dockerfile"
cat >Dockerfile <<EOL
FROM python:3.13-slim

RUN useradd -m -u 1000 tsync_docker

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

ENV PATH="/home/tsync_docker/.local/bin:${PATH}"

COPY . .

RUN mkdir -p /app/sessions /app/bot_cache && chown -R tsync_docker:tsync_docker /app

USER tsync_docker

CMD ["gunicorn", "--workers", "3", "--bind", "0.0.0.0:8000", "main:app"]
EOL

echo "Create nginx.conf file"
cat >nginx.conf <<'EOL' # Quoting the delimiter prevents Bash from expanding any internal $ variables
server {
    listen 80;

    # Permits max 20MB files
    client_max_body_size 20M;

    location / {
        proxy_pass http://tsync_app:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /static/ {
        alias /app/static/;
        expires 30d;
        add_header Cache-Control "public";
    }
}
EOL

echo "Create python requirements.txt file"
cat >requirements.txt <<EOL
anyio>=4.12.1
APScheduler>=3.11.2
asgiref>=3.11.0
blinker>=1.9.0
cachelib>=0.13.0
certifi>=2026.1.4
charset-normalizer>=3.4.4
click>=8.3.1
Deprecated>=1.3.1
dnspython>=2.8.0
Flask>=3.1.2
Flask-APScheduler>=1.13.1
Flask-Limiter>=4.1.1
Flask-Session>=0.8.0
Flask-WTF>=1.2.2
googletrans>=4.0.2
h11>=0.16.0
h2>=4.3.0
hpack>=4.1.0
httpcore>=1.0.9
httpx>=0.28.1
hyperframe>=6.1.0
idna>=3.11
itsdangerous>=2.2.0
Jinja2>=3.1.6
limits>=5.6.0
MarkupSafe>=3.0.3
msgspec>=0.20.0
ordered-set>=4.1.0
packaging>=26.0
pillow>=12.1.0
pymongo>=4.16.0
python-dateutil>=2.9.0.post0
pytz>=2025.2
requests>=2.32.5
six>=1.17.0
sniffio>=1.3.1
typing_extensions>=4.15.0
tzlocal>=5.3.1
urllib3>=2.6.3
Werkzeug>=3.1.5
wrapt>=2.0.1
WTForms>=3.2.1
gunicorn
EOL

echo "Stop flask and nginx containers"
docker stop "$FLASK_CONTAINER_NAME"
docker stop "$NGINX_PROXY_CONTAINER_NAME"

echo "Remove old containers"
docker compose down -v --rmi all

echo "Remove configurations files if exists"
rm -f -- docker-compose.yml
rm -f -- Dockerfile
rm -f -- nginx.conf
rm -f -- requirements.txt

echo "Finished!"