# podman

## Building images
```
# Simple build command that builds to the current directory using the file labeled Dockerfile.
podman build -t image-name .
```

## Extracting IP address
```
podman inspect -f '{{ .NetworkSettings.IPAddress }}' <container_name_or_container_id>
```

