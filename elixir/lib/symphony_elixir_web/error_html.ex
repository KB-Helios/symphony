defmodule SymphonyElixirWeb.ErrorHTML do
  @moduledoc """
  Standalone error pages (rendered without the app layout) styled to match the
  observability dashboard's design tokens. Intentionally dependency-free: no
  asset pipeline, no LiveView, so error pages keep working when the stack is
  unhealthy.
  """

  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns) do
    status = Phoenix.Controller.status_message_from_template(template)
    status_code = template |> String.split(".") |> List.first() |> String.upcase()

    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="color-scheme" content="light dark" />
        <title>Symphony — #{status}</title>
        <style>
          :root {
            --background: 262 20% 98%;
            --foreground: 262 47% 11%;
            --card: 0 0% 100%;
            --muted-foreground: 262 9% 46%;
            --border: 262 21% 89%;
            --primary: 262 83% 58%;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --background: 262 30% 8%;
              --foreground: 262 30% 96%;
              --card: 262 24% 13%;
              --muted-foreground: 262 15% 61%;
              --border: 262 18% 24%;
              --primary: 262 80% 72%;
            }
          }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            background: hsl(var(--background));
            color: hsl(var(--foreground));
            font-family: "Inter", "SF Pro Text", "Helvetica Neue", "Segoe UI", system-ui, sans-serif;
            -webkit-font-smoothing: antialiased;
          }
          .card {
            max-width: 26rem;
            margin: 1rem;
            padding: 2.5rem 2rem;
            text-align: center;
            background: hsl(var(--card));
            border: 1px solid hsl(var(--border));
            border-radius: 1rem;
            box-shadow: 0 8px 24px hsl(var(--foreground) / 0.06);
          }
          .mark {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 2.5rem;
            height: 2.5rem;
            margin-bottom: 1.25rem;
            border-radius: 0.75rem;
            background: hsl(var(--primary));
            color: white;
            font-weight: 700;
            font-size: 0.95rem;
          }
          .status {
            margin: 0;
            font-size: 0.75rem;
            font-weight: 600;
            letter-spacing: 0.14em;
            text-transform: uppercase;
            color: hsl(var(--primary));
          }
          .message {
            margin: 0.5rem 0 1.5rem;
            font-size: 1.25rem;
            font-weight: 600;
            letter-spacing: -0.01em;
          }
          a {
            color: hsl(var(--primary));
            font-size: 0.875rem;
            font-weight: 500;
            text-decoration: none;
          }
          a:hover { text-decoration: underline; }
          .meta { margin-top: 1.75rem; font-size: 0.75rem; color: hsl(var(--muted-foreground)); }
        </style>
      </head>
      <body>
        <main class="card" role="alert">
          <span class="mark">S</span>
          <p class="status">#{status_code}</p>
          <p class="message">#{status}</p>
          <a href="/">Back to the dashboard</a>
          <p class="meta">Symphony &middot; Observability</p>
        </main>
      </body>
    </html>
    """
  end
end
