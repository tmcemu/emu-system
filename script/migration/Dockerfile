FROM python:3.12

COPY script/migration/requirements.txt script/migration/requirements.txt

RUN cd script/migration/ && pip install --index-url https://pypi.org/simple --no-cache-dir -r requirements.txt

WORKDIR /root