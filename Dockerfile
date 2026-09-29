FROM python:3.12-slim

WORKDIR /usr/src/app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY rgw_exporter.py .

RUN useradd --system --no-create-home exporter
USER exporter

EXPOSE 9242

ENTRYPOINT [ "python", "-u", "./rgw_exporter.py" ]
CMD []
