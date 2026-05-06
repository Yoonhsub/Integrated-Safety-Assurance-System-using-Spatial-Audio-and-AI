from fastapi import FastAPI

from app.api.routes import geofence, notifications, ride_requests, bus_info_gateway, driver_ride_requests

app = FastAPI(
    title="MOBI Backend API",
    version="0.1.0-architecture",
    description="FastAPI skeleton for geofencing, Firebase/FCM, ride matching, and bus info gateway.",
)

app.include_router(geofence.router, prefix="/geofence", tags=["geofence"])
app.include_router(notifications.router, prefix="/notifications", tags=["notifications"])
app.include_router(ride_requests.router, prefix="/ride-requests", tags=["ride-requests"])
app.include_router(bus_info_gateway.router, prefix="/bus-info", tags=["bus-info-gateway"])
app.include_router(driver_ride_requests.router, prefix="/drivers", tags=["driver-ride-requests"])


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "mobi-backend-api"}
