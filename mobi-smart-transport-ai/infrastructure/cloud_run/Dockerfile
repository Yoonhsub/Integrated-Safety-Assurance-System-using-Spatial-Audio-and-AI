FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PYTHONPATH=/srv/mobi:/srv/mobi/backend/api
WORKDIR /srv/mobi
RUN apt-get update && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/*
COPY backend/api/requirements.txt backend/api/requirements.txt
RUN pip install --no-cache-dir -r backend/api/requirements.txt \
    && useradd --create-home --uid 10001 mobi
COPY .env.example .env.example
COPY backend/api/app backend/api/app
COPY services/public_data/public_data_client services/public_data/public_data_client
COPY services/public_data/examples services/public_data/examples
USER mobi
EXPOSE 8080
CMD ["python", "-B", "-m", "app.cloud_run"]
