FROM alpine:3.13

RUN apk add bash postgresql-bdr-client

COPY . ./

RUN chmod +x bootstrap.sh

CMD ["/bootstrap.sh"]
