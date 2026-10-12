"""Explicit authentication injection for legacy behavior tests only."""
import pytest
from app.main import app
from app.security import Principal, current_principal, get_principal


@pytest.fixture(autouse=True)
def legacy_test_principal(request):
    if request.node.get_closest_marker("auth_boundary"):
        yield
        return
    principal = Principal("test-admin", "admin")
    previous = dict(app.dependency_overrides)
    app.dependency_overrides[get_principal] = lambda: principal
    marker = current_principal.set(principal)
    try:
        yield
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(previous)
        current_principal.reset(marker)
