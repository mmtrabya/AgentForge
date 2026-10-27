
import os


class Settings:
    APP_NAME = os.getenv("APP_NAME", "AgentForge Backend")
    APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
    DEBUG = os.getenv("DEBUG", "false").lower() == "true"


settings = Settings()

