extends Control

@onready var topic_menu: OptionButton = $Panel/VBox/TopicMenu
@onready var theme_menu: OptionButton = $Panel/VBox/ThemeMenu
@onready var start_button: Button = $Panel/VBox/StartButton

var selected_topic: String
var selected_theme: String

func _ready():
	topic_menu.add_item("sci-fi")
	topic_menu.add_item("high fantasy")
	topic_menu.add_item("urban fantasy")
	topic_menu.add_item("historical")
	topic_menu.add_item("realistic")
	topic_menu.add_item("dream world")
	topic_menu.add_item("techno-mystic")

	theme_menu.add_item("horror")
	theme_menu.add_item("drama")
	theme_menu.add_item("philosophical")
	theme_menu.add_item("combat")
	theme_menu.add_item("romantic")
	theme_menu.add_item("mystical")
	theme_menu.add_item("satirical")

	start_button.pressed.connect(_on_start_pressed)

func _on_start_pressed():
	if topic_menu.selected == -1 or theme_menu.selected == -1:
		print("⚠️ Please select both a topic and a theme.")
		return

	selected_topic = topic_menu.get_item_text(topic_menu.selected).capitalize()
	selected_theme = theme_menu.get_item_text(theme_menu.selected).capitalize()

	var game_scene = load("res://Main/Game.tscn").instantiate()
	get_tree().root.add_child(game_scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = game_scene
	print("🌟 Loaded Game Scene with Topic:", selected_topic, "| Theme:", selected_theme)
	game_scene.call("set_topic_and_theme", selected_topic, selected_theme)
