# MicroNet App

## Development Using docker-compose
(For wins, change the bin/rails into LF)

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

Run the tests. (Optional)

```shell
docker-compose run --rm test
```

### Checking email in Development

When running locally using the `docker-compose.yml` file included in the project,
a instance of [InBucket](https://inbucket.org/) will be started in a container.
In `config/development.rb`, the smtp server is set to use InBucket so to see if
the email is working, visit [http://localhost:9000](http://localhost:9000).