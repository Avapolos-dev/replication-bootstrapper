FROM alpine:3.13

RUN apk update

RUN apk add --upgrade bash postgresql-bdr-client

COPY bootstrap.sh .

RUN chmod +x bootstrap.sh

CMD ["/bootstrap.sh"]

