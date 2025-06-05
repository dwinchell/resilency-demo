podman build -f Dockerfile.frontend -t my-frontend-app .
podman run -d -p 8080:80 --name frontend-container my-frontend-app
podman  build -f Dockerfile.backend -t my-backend-app .
podman  run -d -p 3000:3000 --name backend-container my-backend-app

