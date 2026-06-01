FROM python:3.11-slim

WORKDIR /app

# Install dependencies first so the layer caches and Snyk can detect the
# installed packages (incl. atlan-application-sdk) in the built image.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Run as non-root.
RUN useradd --create-home appuser
USER appuser

CMD ["python", "main.py"]
