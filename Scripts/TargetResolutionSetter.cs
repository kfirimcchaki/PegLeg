using Godot;
using System;
using System.Text.Json.Nodes;

public partial class AppConfig
{
	public float uiScale;
}

public partial class TargetResolutionSetter : Node
{
	[Export]
	Control rootNode;
	[Export]
	Vector2I TargetResolution = new(950, 720);
	[Export]
	Vector2I MinResolution = new(360, 360);
	[Export]
	bool forceVertical;
	[Export]
	bool allowResize;
	[Export]
	bool onlyExpandWhenSmaller;
	[Export]
	double resizeIncrement = 0.05f;
	[Export]
	float resizeMin = 0.5f;
	[Export]
	float resizeMax = 1.0f;
	[Export]
	bool adaptToMobileSafeArea = true;
	Window curWindow;

	const string safeAreaTargetName = "Content";
	MarginContainer safeAreaTarget;
	Vector4I safeAreaBaseMargins;
	bool safeAreaBaseCaptured;

	// Called when the node enters the scene tree for the first time.
	public override void _Ready()
	{
		curWindow = GetTree().Root;
		curWindow.SizeChanged += WindowSizeChanged;
		curWindow.MinSize = MinResolution;
		SetSize((float)AppConfig.Get("ui", "scale", 1.0));
		if (rootNode is not null)
		{
			rootNode.ResetOffsets();
			rootNode.ResetAnchors();
		}
		if (OS.HasFeature("mobile"))
		{
			DisplayServer.ScreenSetOrientation(forceVertical ? DisplayServer.ScreenOrientation.SensorPortrait : DisplayServer.ScreenOrientation.Sensor);
			// Android specifics: keep the interface clear of display cutouts/gesture areas and
			// make the hardware/gesture back button behave like it does in a native app.
			curWindow.GoBackRequested += OnBackRequested;
			ApplySafeAreaPadding();
		}
		AppConfig.OnConfigChanged += OnConfigChanged;
	}

	private void WindowSizeChanged()
	{
		SetSize((float)AppConfig.Get("ui", "scale", 1.0));
		if (OS.HasFeature("mobile"))
			ApplySafeAreaPadding();
	}

	/// <summary>
	/// Pads the main content container with the device's safe area insets so that nothing ends up
	/// under a display cutout (notch/camera hole) or behind the Android gesture bar. Devices that
	/// report no insets (or platforms without safe areas) are left completely untouched.
	/// </summary>
	void ApplySafeAreaPadding()
	{
		try
		{
			if (!adaptToMobileSafeArea)
				return;
			safeAreaTarget ??= FindSafeAreaTarget();
			if (safeAreaTarget is null)
				return;
			if (!safeAreaBaseCaptured)
			{
				safeAreaBaseMargins = new(
					safeAreaTarget.GetThemeConstant("margin_left"),
					safeAreaTarget.GetThemeConstant("margin_top"),
					safeAreaTarget.GetThemeConstant("margin_right"),
					safeAreaTarget.GetThemeConstant("margin_bottom"));
				safeAreaBaseCaptured = true;
			}

			Rect2I safeArea = DisplayServer.GetDisplaySafeArea();
			Vector2I windowPos = DisplayServer.WindowGetPosition();
			Vector2I windowSize = DisplayServer.WindowGetSize();
			if (windowSize.X <= 0 || windowSize.Y <= 0 || safeArea.Size.X <= 0 || safeArea.Size.Y <= 0)
				return;

			int left = Mathf.Max(0, safeArea.Position.X - windowPos.X);
			int top = Mathf.Max(0, safeArea.Position.Y - windowPos.Y);
			int right = Mathf.Max(0, windowPos.X + windowSize.X - safeArea.Position.X - safeArea.Size.X);
			int bottom = Mathf.Max(0, windowPos.Y + windowSize.Y - safeArea.Position.Y - safeArea.Size.Y);

			// Screen pixels -> interface units (canvas_items stretch scales uniformly).
			Vector2I contentSize = curWindow.ContentScaleSize;
			float scale = Mathf.Min(
				contentSize.X <= 0 ? 1f : (float)windowSize.X / contentSize.X,
				contentSize.Y <= 0 ? 1f : (float)windowSize.Y / contentSize.Y);
			if (scale <= 0f)
				scale = 1f;

			safeAreaTarget.AddThemeConstantOverride("margin_left", safeAreaBaseMargins.X + Mathf.CeilToInt(left / scale));
			safeAreaTarget.AddThemeConstantOverride("margin_top", safeAreaBaseMargins.Y + Mathf.CeilToInt(top / scale));
			safeAreaTarget.AddThemeConstantOverride("margin_right", safeAreaBaseMargins.Z + Mathf.CeilToInt(right / scale));
			safeAreaTarget.AddThemeConstantOverride("margin_bottom", safeAreaBaseMargins.W + Mathf.CeilToInt(bottom / scale));
		}
		catch (Exception e)
		{
			GD.PushWarning("Could not apply display safe area padding: " + e.Message);
		}
	}

	MarginContainer FindSafeAreaTarget() =>
		rootNode?.GetNodeOrNull<MarginContainer>(safeAreaTargetName);

	/// <summary>
	/// Android back button/gesture. Overlays close themselves through ModalWindow (they listen to
	/// the same window signal and only user closable top windows react), an open context menu is
	/// dismissed next, then back walks the main tab bar down to its first tab before finally
	/// leaving the app - the behaviour Android users expect from a native app.
	/// </summary>
	void OnBackRequested()
	{
		try
		{
			if (!OS.HasFeature("mobile"))
				return;
			if (!ModalWindow.StackEmpty())
				return;
			if (ContextMenu.CloseOpenMenu())
				return;
			if (AnyOtherWindowVisible(GetTree().Root))
				return;
			if (FindMainTabBar(GetTree().Root)?.GoBackToFirstTab() == true)
				return;
			GetTree().Quit();
		}
		catch (Exception e)
		{
			GD.PushWarning("Back button handling failed: " + e.Message);
		}
	}

	/// <summary>Finds the primary tab bar of the interface ("TabButtons", also present in the lite UI).</summary>
	static VirtualTabBar FindMainTabBar(Node node)
	{
		if (node is VirtualTabBar tabBar && tabBar.Name == "TabButtons")
			return tabBar;
		foreach (Node child in node.GetChildren())
		{
			var found = FindMainTabBar(child);
			if (found is not null)
				return found;
		}
		return null;
	}

	static bool AnyOtherWindowVisible(Node node)
	{
		foreach (Node child in node.GetChildren())
		{
			if (child is Window window)
			{
				if (window.Visible && window != node)
					return true;
				continue;
			}
			if (AnyOtherWindowVisible(child))
				return true;
		}
		return false;
	}

	public override void _Notification(int what)
	{
		// Insets (display cutout, gesture bar) can change while the app is in the background.
		if (what == NotificationApplicationResumed && OS.HasFeature("mobile"))
			ApplySafeAreaPadding();
	}

	public override void _Input(InputEvent @event)
	{
		if (!allowResize)
			return;
		if (@event is InputEventMouseButton mouseInput)
		{
			if (!mouseInput.CtrlPressed || !mouseInput.Pressed || (mouseInput.ButtonIndex != MouseButton.WheelUp && mouseInput.ButtonIndex != MouseButton.WheelDown))
				return;
			TryScroll(mouseInput.ButtonIndex == MouseButton.WheelUp);
			GetViewport().SetInputAsHandled();
		}
		else if(@event is InputEventKey keyInput)
		{
			if (!keyInput.CtrlPressed || !keyInput.Pressed || (keyInput.Keycode != Key.Equal && keyInput.Keycode != Key.Minus))
				return;
			TryScroll(keyInput.Keycode == Key.Equal);
			GetViewport().SetInputAsHandled();
		}
	}

	void TryScroll(bool up)
	{
		double currentZoom = AppConfig.Get("ui", "scale", 1.0);
		double currentRealZoom = CalcRealZoom(currentZoom);
		double newZoom = currentRealZoom + (up ? resizeIncrement : -resizeIncrement);
		newZoom = Math.Round(Math.Clamp(newZoom, resizeMin, resizeMax), 2);
		if (newZoom != currentZoom)
			AppConfig.Set("ui", "scale", newZoom);
	}

	double CalcRealZoom(double value)
	{
		Vector2 targetRes = TargetResolution;
		if (onlyExpandWhenSmaller)
			targetRes = new(Mathf.Max(TargetResolution.X, curWindow.Size.X), Mathf.Max(TargetResolution.Y, curWindow.Size.Y));
		float scaleFactor = (float)Mathf.Clamp(value, resizeMin, resizeMax);
		var prescaled = targetRes;
		targetRes /= scaleFactor;
		targetRes = new(Mathf.Max(targetRes.X, TargetResolution.X), Mathf.Max(targetRes.Y, TargetResolution.Y));
		double realZoom = Mathf.Min(prescaled.X / targetRes.X, prescaled.Y / targetRes.Y);
		realZoom = Math.Round(Math.Round(realZoom / resizeIncrement) * resizeIncrement, 2);
		return realZoom;
	}

	public override void _ExitTree()
	{
		AppConfig.OnConfigChanged -= OnConfigChanged;
		curWindow.SizeChanged -= WindowSizeChanged;
		if (OS.HasFeature("mobile") && IsInstanceValid(curWindow))
			curWindow.GoBackRequested -= OnBackRequested;
	}

	private void OnConfigChanged(string section, string key, JsonNode node)
	{
		if (section != "ui" || key != "scale" || node is not JsonValue property)
			return;

		SetSize((float)property.GetValue<double>());
	}

	void SetSize(float value)
	{
		Vector2 targetRes = TargetResolution;
		if (onlyExpandWhenSmaller)
			targetRes = new(Mathf.Max(TargetResolution.X, curWindow.Size.X), Mathf.Max(TargetResolution.Y, curWindow.Size.Y));
		float scaleFactor = Mathf.Clamp(value, resizeMin, resizeMax);
		targetRes /= scaleFactor;
		targetRes = new(Mathf.Max(targetRes.X, TargetResolution.X), Mathf.Max(targetRes.Y, TargetResolution.Y));

		curWindow.ContentScaleSize = (Vector2I)targetRes;
	}
}
