import logging

from fastapi import FastAPI

from app.config import settings
from app.logging_config import setup_logging

setup_logging()

logger = logging.getLogger(__name__)

app = FastAPI(title=settings.APP_NAME)


@app.get("/health")
def health_check():
    logger.info("Health check requested")
    return {"status": "ok"}