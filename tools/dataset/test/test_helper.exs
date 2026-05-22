# capture_log: true sends Logger output (the [corpus]/[merge]/[build]
# progress lines) to a per-test buffer that's only printed if the test
# fails — so a green run stays quiet.
ExUnit.start(capture_log: true)
