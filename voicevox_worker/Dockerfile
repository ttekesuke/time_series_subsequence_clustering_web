FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1
COPY voicevox_worker/worker.py /worker/worker.py

EXPOSE 9120
CMD ["python", "/worker/worker.py"]