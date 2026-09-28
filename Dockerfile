FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# 依赖（FastAPI / uvicorn / tzdata）随镜像构建一次装齐，容器启动即完成初始化，
# 无需再做任何准备步骤；/expand … /handoff-route 全部接口随服务一键启动
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000

# 服务固定监听 8000；容器启动即可用：http://localhost:8000/docs
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
