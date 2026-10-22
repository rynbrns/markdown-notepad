# Hostile fixture

<script>window.alert("executed")</script>

<img src="https://evil.example/tracker.png" onerror="alert('xss')">

<iframe src="https://evil.example/frame"></iframe>

<style>body { background: url(https://evil.example/bg.png); }</style>

[click me](javascript:alert('xss'))

[runs data url](data:text/html,<script>alert(1)</script>)

![remote](https://evil.example/remote.png)

![protocol relative](//evil.example/relative.png)

![absolute](file:///etc/passwd)

![local](pictures/ok.png)

Normal **text** after the hostile payload.
