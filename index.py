"""Vercel FastAPI entrypoint.

Vercel detects FastAPI applications from supported root-level entrypoints.
The application implementation remains in api/app.py.
"""
from api.app import app

__all__ = ["app"]
