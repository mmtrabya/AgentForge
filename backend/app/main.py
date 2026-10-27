
from fastapi import FastAPI

from backend.app.core.config import settings
from backend.app.core.logging_config import setup_logging

# Initialize logging
logger = setup_logging()

# Create FastAPI application
app = FastAPI(
    title=settings.APP_NAME,
    version=settings.APP_VERSION
)


@app.get("/")
def home():
    logger.info("Home endpoint accessed")

    return {
        "message": f"Welcome to {settings.APP_NAME}"
    }


@app.get("/health")
def health_check():
    logger.info("Health check requested")

    return {
        "status": "healthy",
        "version": settings.APP_VERSION
    }
