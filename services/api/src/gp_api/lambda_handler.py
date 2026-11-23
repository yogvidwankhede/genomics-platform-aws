"""Lambda entry point (function URL payload v2 -> ASGI)."""

from mangum import Mangum

from gp_api.main import app

handler = Mangum(app, lifespan="off")
