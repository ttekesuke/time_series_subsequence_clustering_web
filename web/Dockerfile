# gemインストールのみに使用
FROM ruby:3.1.1-alpine as builder

ENV ROOT="/app"
ENV LANG=C.UTF-8
ENV TZ=Asia/Tokyo

WORKDIR ${ROOT}

COPY Gemfile Gemfile.lock ${ROOT}

RUN apk add \
    alpine-sdk \
    build-base \
    postgresql-dev \
    postgresql-client \
    tzdata \
    git



RUN gem install bundler && bundle install

# マルチステージビルド
FROM ruby:3.1.1-alpine AS runner

ENV ROOT="/app"
ENV LANG=C.UTF-8
ENV TZ=Asia/Tokyo

WORKDIR ${ROOT}

RUN apk update && \
    apk add \
        postgresql-dev \
        tzdata \
        bash \
        gcompat \
        vim

RUN apk add --no-cache nodejs

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . ${ROOT}
COPY entrypoint.sh /usr/bin/

RUN chmod +x /usr/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
EXPOSE 3000

CMD ["rails", "server", "-b", "0.0.0.0"]