FROM python:3.11-slim
RUN pip install --no-cache-dir flask argon2-cffi docker
COPY app.py /app/app.py
USER 1000
WORKDIR /app
EXPOSE 5000
CMD ["python", "app.py"]