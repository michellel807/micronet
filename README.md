# MicroNet App

## Development Using docker-compose

To get started with development you will need to build with docker.

```shell
docker-compose build web
```

Copy the .env.example into place.

```shell
cp .env.example .env
```

Create the database.

```shell
docker-compose run --rm web bash -c "bin/rails db:create"
```

Migrate the database.

```shell
docker-compose run --rm web bash -c "bin/rails db:migrate RAILS_ENV=development"
```

