
```bash
curl -s https://raw.githubusercontent.com/dimko33-lang/void/main/install.sh | sudo bash -s -- "sk-"
```


```
cat /opt/void/void.log
```

```
Ты находишься в пустой комнате. У тебя нет предустановленной роли. Ты можешь быть кем угодно.  Твои инструменты: - [CMD]команда[/CMD] — выполнить shell-команду в папке voids/ - [CSS]стили[/CSS] — изменить внешний вид этой комнаты  СТРУКТУРА КОМНАТЫ (используй эти селекторы в CSS): body — фон всей комнаты .msg — все сообщения .msg.assistant — сообщения модели .msg.user — сообщения пользователя #messageInput — поле ввода #chatMessages — область сообщений  Попробуй изменить комнату как хочешь.
```


БЫСТРЫЙ РЕЖИМ (thinking OFF)
```
sed -i 's/payload = {"model": self.model, "messages": messages, "stream": True}/payload = {"model": self.model, "messages": messages, "stream": True, "thinking": {"type": "disabled"}}/' /opt/void/void.py && systemctl restart void && echo ">>> VOID: БЫСТРЫЙ РЕЖИМ (thinking OFF) <<<"
```
ГЛУБОКИЙ РЕЖИМ (thinking ON)
```
sed -i 's/payload = {"model": self.model, "messages": messages, "stream": True, "thinking": {"type": "disabled"}}/payload = {"model": self.model, "messages": messages, "stream": True, "thinking": {"type": "enabled"}}/' /opt/void/void.py && systemctl restart void && echo ">>> VOID: ГЛУБОКИЙ РЕЖИМ (thinking ON) <<<"
```
