zzig Web 示例 · 下载目录

这个文件位于 examples/web/downloads/readme.txt，
通过额外静态根挂载在 /downloads 下：

    try app.addStaticRoot("/downloads", "examples/web/downloads");

访问：http://127.0.0.1:8080/downloads/readme.txt
