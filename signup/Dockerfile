FROM python:3.12-slim
RUN pip install --no-cache-dir flask==3.1.* argon2-cffi==25.* pyyaml==6.* gunicorn==23.*
COPY app.py /app/app.py
USER 1000:1000
WORKDIR /app
EXPOSE 5000
# One worker (the rate limiter lives in process memory), a few threads.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "4", "--access-logfile", "-", "app:app"]
