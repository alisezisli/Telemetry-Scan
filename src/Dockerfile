FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir psycopg2-binary==2.9.9
COPY telemetry-gateway.py .
EXPOSE 20777/udp
CMD ["python3", "/app/telemetry-gateway.py"]