
import logging


def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)s | %(name)s | %(message)s"
    )

    logger = logging.getLogger("AgentForge")
    logger.info("Logging system initialized")

    return logger
