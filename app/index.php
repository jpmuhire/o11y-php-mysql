<?php
declare(strict_types=1);

$dbHost = getenv('DB_HOST') ?: '10.42.1.4';
$dbName = getenv('DB_NAME') ?: 'appdb';
$dbUser = getenv('DB_USER') ?: 'appuser';
$dbPass = getenv('DB_PASS') ?: '';

$message = null;
$error = null;

try {
    $pdo = new PDO(
        "mysql:host={$dbHost};dbname={$dbName};charset=utf8mb4",
        $dbUser,
        $dbPass,
        [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]
    );

    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $name = trim((string)($_POST['name'] ?? ''));
        $email = trim((string)($_POST['email'] ?? ''));
        $msg = trim((string)($_POST['message'] ?? ''));

        if ($name === '') {
            $error = 'Name is required.';
        } else {
            $stmt = $pdo->prepare(
                'INSERT INTO entries (name, email, message) VALUES (:n, :e, :m)'
            );
            $stmt->execute([':n' => $name, ':e' => $email, ':m' => $msg]);
            $message = 'Saved entry #' . $pdo->lastInsertId();
        }
    }

    $rows = $pdo->query(
        'SELECT id, name, email, message, created_at FROM entries ORDER BY id DESC LIMIT 25'
    )->fetchAll();
} catch (Throwable $e) {
    $error = 'Database error: ' . $e->getMessage();
    $rows = [];
}

function h(?string $s): string { return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8'); }
?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>o11y PHP + MySQL demo</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 760px; margin: 2rem auto; padding: 0 1rem; }
  form { display: grid; gap: .5rem; margin-bottom: 2rem; }
  input, textarea, button { font: inherit; padding: .5rem; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #ddd; padding: .4rem .6rem; text-align: left; font-size: .9rem; }
  .ok { color: #0a7d2c; } .err { color: #b00020; }
</style>
</head>
<body>
<h1>Submit an entry</h1>
<?php if ($message): ?><p class="ok"><?= h($message) ?></p><?php endif; ?>
<?php if ($error):   ?><p class="err"><?= h($error)   ?></p><?php endif; ?>
<form method="post">
  <label>Name <input name="name" required maxlength="120"></label>
  <label>Email <input name="email" type="email" maxlength="180"></label>
  <label>Message <textarea name="message" rows="4" maxlength="2000"></textarea></label>
  <button type="submit">Save</button>
</form>

<h2>Latest entries</h2>
<table>
  <thead><tr><th>ID</th><th>Name</th><th>Email</th><th>Message</th><th>When</th></tr></thead>
  <tbody>
  <?php foreach ($rows as $r): ?>
    <tr>
      <td><?= (int)$r['id'] ?></td>
      <td><?= h($r['name']) ?></td>
      <td><?= h($r['email']) ?></td>
      <td><?= h($r['message']) ?></td>
      <td><?= h($r['created_at']) ?></td>
    </tr>
  <?php endforeach; ?>
  </tbody>
</table>
<p style="margin-top:2rem;color:#888">Host: <?= h(gethostname()) ?> | DB: <?= h($dbHost) ?></p>
</body>
</html>
