# MicroNet App

## Development Using docker-compose

To get started with development you will need to build with docker.

```
docker-compose build web
```

After building an image, you will need to migrate the database.


```shell
docker-compose run --rm web bash -c "bin/rails db:migrate RAILS_ENV=development"
```

