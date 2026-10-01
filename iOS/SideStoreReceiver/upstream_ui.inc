
#pragma mark - Upstream DiPlay UIKit parity

- (UIColor *)upstreamBGColor {
    return [UIColor colorWithRed:12/255.0 green:17/255.0 blue:27/255.0 alpha:1];
}
- (UIColor *)upstreamSurfaceColor {
    return [UIColor colorWithRed:21/255.0 green:30/255.0 blue:44/255.0 alpha:1];
}
- (UIColor *)upstreamBorderColor {
    return [UIColor colorWithRed:42/255.0 green:56/255.0 blue:75/255.0 alpha:1];
}
- (UIColor *)upstreamAccentColor {
    return [UIColor colorWithRed:166/255.0 green:200/255.0 blue:255/255.0 alpha:1];
}
- (UIColor *)upstreamTextColor {
    return [UIColor colorWithRed:241/255.0 green:245/255.0 blue:252/255.0 alpha:1];
}
- (UIColor *)upstreamMutedColor {
    return [UIColor colorWithRed:168/255.0 green:182/255.0 blue:202/255.0 alpha:1];
}

- (UIButton *)upstreamButtonWithTitle:(NSString *)title
                              primary:(BOOL)primary
                               action:(void (^)(void))action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    [self styleUpstreamButton:button primary:primary];
    [button.heightAnchor constraintEqualToConstant:60].active = YES;
    if (action) {
        [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *sender) {
            (void)sender;
            action();
        }] forControlEvents:UIControlEventTouchUpInside];
    }
    return button;
}

- (UIStackView *)upstreamVerticalStack:(CGFloat)spacing {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFill;
    stack.spacing = spacing;
    return stack;
}

- (UIView *)upstreamSectionWithTitle:(NSString *)title
                              symbol:(NSString *)symbol
                               stack:(UIStackView **)outStack {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [self upstreamSurfaceColor];
    card.layer.cornerRadius = 20;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [self upstreamBorderColor].CGColor;

    UIStackView *content = [self upstreamVerticalStack:12];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [content.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [content.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-22],
    ]];

    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 10;
    if (symbol.length) {
        UIImage *image = [UIImage systemImageNamed:symbol];
        UIImageView *icon = [[UIImageView alloc] initWithImage:image];
        icon.tintColor = [self upstreamAccentColor];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [icon.widthAnchor constraintEqualToConstant:24].active = YES;
        [icon.heightAnchor constraintEqualToConstant:24].active = YES;
        [header addArrangedSubview:icon];
    }
    [header addArrangedSubview:[self upstreamLabel:title
                                              size:22
                                             color:[self upstreamTextColor]
                                              bold:YES]];
    [content addArrangedSubview:header];
    if (outStack) *outStack = content;
    return card;
}

- (void)upstreamAddToggleTo:(UIStackView *)parent
                      title:(NSString *)title
                description:(NSString *)description
                      value:(BOOL)value
                    changed:(void (^)(BOOL value))changed {
    UIStackView *line = [[UIStackView alloc] init];
    line.axis = UILayoutConstraintAxisHorizontal;
    line.alignment = UIStackViewAlignmentCenter;
    line.spacing = 16;

    UIStackView *text = [self upstreamVerticalStack:6];
    UILabel *titleLabel = [self upstreamLabel:title
                                         size:18
                                        color:[self upstreamTextColor]
                                         bold:YES];
    UILabel *descriptionLabel = [self upstreamLabel:description
                                               size:14
                                              color:[self upstreamMutedColor]
                                               bold:NO];
    [text addArrangedSubview:titleLabel];
    [text addArrangedSubview:descriptionLabel];
    [line addArrangedSubview:text];

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.onTintColor = [self upstreamAccentColor];
    toggle.on = value;
    [toggle setContentHuggingPriority:UILayoutPriorityRequired
                             forAxis:UILayoutConstraintAxisHorizontal];
    __weak UISwitch *weakToggle = toggle;
    if (changed) {
        [toggle addAction:[UIAction actionWithHandler:^(__kindof UIAction *sender) {
            (void)sender;
            changed(weakToggle.isOn);
        }] forControlEvents:UIControlEventValueChanged];
    }
    [line addArrangedSubview:toggle];
    [parent addArrangedSubview:line];
}

- (void)upstreamReconnectCurrentMode {
    NSInteger savedMode = self.sideStoreMode;
    if (self.state == StateIdle) {
        self.sideStoreMode = savedMode;
        [self attemptStart];
        return;
    }
    [self stopFlow];
    __weak typeof(self) weakSelf = self;
    __block NSInteger attempts = 0;
    __block void (^poll)(void);
    poll = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        attempts++;
        if (strongSelf.state == StateIdle) {
            strongSelf.sideStoreMode = savedMode;
            [strongSelf attemptStart];
            return;
        }
        if (attempts < 50) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), poll);
        }
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), poll);
}

- (UIButton *)upstreamAddChoiceTo:(UIStackView *)parent
                            title:(NSString *)title
                          options:(NSArray<NSString *> *)options
                           values:(NSArray<NSNumber *> *)values
                       currentKey:(NSString *)key
                     defaultValue:(NSInteger)defaultValue
                       reconnects:(BOOL)reconnects {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger value = [defaults objectForKey:key] ? [defaults integerForKey:key] : defaultValue;
    __block NSInteger selected = [values indexOfObject:@(value)];
    if (selected == NSNotFound) selected = 0;

    UIButton *button = [self upstreamButtonWithTitle:
        [NSString stringWithFormat:@"%@ · %@", title, options[selected]]
        primary:NO action:nil];
    __weak UIButton *weakButton = button;
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *sender) {
        (void)sender;
        __block NSInteger pending = selected;
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:title
                                                message:nil
                                         preferredStyle:UIAlertControllerStyleAlert];
        for (NSInteger index = 0; index < (NSInteger)options.count; index++) {
            NSString *option = options[index];
            [alert addAction:[UIAlertAction actionWithTitle:option
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(__unused UIAlertAction *action) {
                pending = index;
                NSNumber *saved = values[pending];
                [defaults setInteger:saved.integerValue forKey:key];
                selected = pending;
                [weakButton setTitle:
                    [NSString stringWithFormat:@"%@ · %@", title, options[selected]]
                              forState:UIControlStateNormal];
                if (reconnects &&
                    (self.state == StateActive ||
                     self.state == StateAwaitingPhone ||
                     self.state == StatePreparingNet)) {
                    [self upstreamReconnectCurrentMode];
                }
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
        [[self topPresenter] presentViewController:alert animated:YES completion:nil];
    }] forControlEvents:UIControlEventTouchUpInside];
    [parent addArrangedSubview:button];
    return button;
}

- (UIViewController *)upstreamPageControllerWithBack:(NSString *)backTitle
                                                 root:(UIStackView **)outRoot {
    UIViewController *page = [[UIViewController alloc] init];
    page.modalPresentationStyle = UIModalPresentationFullScreen;
    page.view.backgroundColor = [self upstreamBGColor];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.backgroundColor = [self upstreamBGColor];
    [page.view addSubview:scroll];

    UIStackView *root = [self upstreamVerticalStack:18];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:page.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:page.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:page.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:page.view.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:32],
        [root.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-32],
        [root.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [root.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [root.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-64],
    ]];

    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;
    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage imageNamed:@"ic_carplay.png"]];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:36].active = YES;
    [icon.heightAnchor constraintEqualToConstant:36].active = YES;
    [header addArrangedSubview:icon];
    [header addArrangedSubview:[self upstreamLabel:@"iPlay"
                                              size:26
                                             color:[self upstreamTextColor]
                                              bold:YES]];
    UIView *spacer = [[UIView alloc] init];
    [header addArrangedSubview:spacer];
    UIButton *back = [self upstreamButtonWithTitle:backTitle ?: @"Back"
                                           primary:NO
                                            action:^{
        [page dismissViewControllerAnimated:YES completion:nil];
    }];
    [back.widthAnchor constraintEqualToConstant:130].active = YES;
    [header addArrangedSubview:back];
    [root addArrangedSubview:header];

    if (outRoot) *outRoot = root;
    return page;
}

- (void)buildUpstreamHomeReal {
    UIView *content = [self rootContentView];
    self.setupOverlay = [[UIView alloc] initWithFrame:content.bounds];
    self.setupOverlay.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.setupOverlay.backgroundColor = [self upstreamBGColor];
    [content addSubview:self.setupOverlay];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.backgroundColor = [self upstreamBGColor];
    [self.setupOverlay addSubview:scroll];

    UIStackView *root = [self upstreamVerticalStack:24];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.setupOverlay.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.setupOverlay.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.setupOverlay.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.setupOverlay.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:32],
        [root.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-32],
        [root.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [root.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [root.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-64],
    ]];

    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;
    self.upstreamHeaderIcon = [[UIImageView alloc] initWithImage:
        [UIImage imageNamed:@"ic_carplay.png"]];
    self.upstreamHeaderIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self.upstreamHeaderIcon.widthAnchor constraintEqualToConstant:36].active = YES;
    [self.upstreamHeaderIcon.heightAnchor constraintEqualToConstant:36].active = YES;
    [header addArrangedSubview:self.upstreamHeaderIcon];
    self.titleLabel = [self upstreamLabel:@"iPlay"
                                     size:26
                                    color:[self upstreamTextColor]
                                     bold:YES];
    [header addArrangedSubview:self.titleLabel];
    [header addArrangedSubview:[[UIView alloc] init]];
    UIButton *home = [self upstreamButtonWithTitle:@"Home" primary:NO action:^{
        [self upstreamHomeTapped];
    }];
    home.tag = 0x4450484d;
    [home.widthAnchor constraintEqualToConstant:130].active = YES;
    [header addArrangedSubview:home];
    [root addArrangedSubview:header];

    UIStackView *hero = [self upstreamVerticalStack:10];
    self.upstreamEyebrowLabel =
        [self upstreamLabel:@"YOUR PHONE. YOUR DRIVE."
                       size:12 color:[self upstreamAccentColor] bold:YES];
    self.upstreamEyebrowLabel.accessibilityLabel = @"Your phone. Your drive.";
    self.upstreamHeroTitleLabel =
        [self upstreamLabel:@"A familiar drive."
                       size:(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone ? 36 : 42)
                      color:[self upstreamTextColor] bold:YES];
    self.upstreamHeroBodyLabel =
        [self upstreamLabel:@"Your maps, music and conversations.\nCarPlay, right here on your display."
                       size:19 color:[self upstreamMutedColor] bold:NO];
    [hero addArrangedSubview:self.upstreamEyebrowLabel];
    [hero addArrangedSubview:self.upstreamHeroTitleLabel];
    [hero addArrangedSubview:self.upstreamHeroBodyLabel];

    UIStackView *cardStack = nil;
    self.upstreamWirelessCard =
        [self upstreamSectionWithTitle:@"WIRELESS CARPLAY" symbol:nil stack:&cardStack];
    self.upstreamWirelessLabel =
        [self upstreamLabel:@"WIRELESS CARPLAY"
                       size:12 color:[self upstreamAccentColor] bold:YES];
    /* Section header already carries the title; keep the property for state compatibility. */
    self.upstreamWirelessLabel.hidden = YES;
    [cardStack insertArrangedSubview:self.upstreamWirelessLabel atIndex:0];

    self.headlineLabel =
        [self upstreamLabel:@"Ready when you are"
                       size:24 color:[self upstreamTextColor] bold:YES];
    [cardStack addArrangedSubview:self.headlineLabel];

    self.primaryButton = [self upstreamButtonWithTitle:@"Connect phone"
                                              primary:YES
                                               action:^{ [self primaryTapped]; }];
    [self.primaryButton.heightAnchor constraintEqualToConstant:68].active = YES;
    [cardStack addArrangedSubview:self.primaryButton];

    self.subtitleLabel =
        [self upstreamLabel:@"Keep LocalDevVPN enabled. iPlay pairs with this iPhone through Developer Mode."
                       size:15 color:[self upstreamMutedColor] bold:NO];
    [cardStack addArrangedSubview:self.subtitleLabel];

    self.secondaryButton = [self upstreamButtonWithTitle:@"Connection mode"
                                                primary:NO
                                                 action:^{ [self secondaryTapped]; }];
    [self.secondaryButton.heightAnchor constraintEqualToConstant:56].active = YES;
    [cardStack addArrangedSubview:self.secondaryButton];

    self.carHintLabel =
        [self upstreamLabel:@"A → A uses LocalDevVPN + trusted Remote Pairing."
                       size:14 color:[self upstreamMutedColor] bold:NO];
    [cardStack addArrangedSubview:self.carHintLabel];

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.color = [self upstreamTextColor];
    self.spinner.hidesWhenStopped = YES;
    [cardStack addArrangedSubview:self.spinner];

    UIStackView *right = [self upstreamVerticalStack:10];
    right.alignment = UIStackViewAlignmentFill;

    UIStackView *branding = [[UIStackView alloc] init];
    branding.axis = UILayoutConstraintAxisVertical;
    branding.alignment = UIStackViewAlignmentCenter;
    self.upstreamBrandIcon = [[UIImageView alloc] initWithImage:
        [UIImage imageNamed:@"ic_carplay.png"]];
    self.upstreamBrandIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self.upstreamBrandIcon.widthAnchor constraintEqualToConstant:96].active = YES;
    [self.upstreamBrandIcon.heightAnchor constraintEqualToConstant:96].active = YES;
    [branding addArrangedSubview:self.upstreamBrandIcon];

    self.receiverButton = [self upstreamButtonWithTitle:@"Receive from another iPhone"
                                               primary:NO
                                                action:^{ [self receiverTapped]; }];
    [right addArrangedSubview:self.receiverButton];
    self.upstreamReceiverHintLabel =
        [self upstreamLabel:@"Use this iPhone as the CarPlay display for another iPhone."
                       size:14 color:[self upstreamMutedColor] bold:NO];
    self.upstreamReceiverHintLabel.textAlignment = NSTextAlignmentCenter;
    [right addArrangedSubview:self.upstreamReceiverHintLabel];

    self.tertiaryButton = [self upstreamButtonWithTitle:@"Settings"
                                               primary:NO
                                                action:^{ [self tertiaryTapped]; }];
    [right addArrangedSubview:self.tertiaryButton];
    self.upstreamSettingsHintLabel =
        [self upstreamLabel:@"Make iPlay feel right for this display."
                       size:14 color:[self upstreamMutedColor] bold:NO];
    self.upstreamSettingsHintLabel.textAlignment = NSTextAlignmentCenter;
    [right addArrangedSubview:self.upstreamSettingsHintLabel];

    self.upstreamPreviewLabel =
        [self upstreamLabel:@"PUBLIC PREVIEW  ·  0.1"
                       size:12 color:[self upstreamMutedColor] bold:NO];
    self.upstreamPreviewLabel.textAlignment = NSTextAlignmentCenter;
    [right addArrangedSubview:self.upstreamPreviewLabel];

    BOOL wide = UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPhone &&
                [self rootContentView].bounds.size.width >= 850.0;
    if (wide) {
        UIStackView *top = [[UIStackView alloc] init];
        top.axis = UILayoutConstraintAxisHorizontal;
        top.alignment = UIStackViewAlignmentTop;
        top.spacing = 40;
        [top addArrangedSubview:hero];
        [top addArrangedSubview:branding];
        [hero.widthAnchor constraintEqualToAnchor:branding.widthAnchor multiplier:1.6].active = YES;
        [root addArrangedSubview:top];

        UIStackView *bottom = [[UIStackView alloc] init];
        bottom.axis = UILayoutConstraintAxisHorizontal;
        bottom.alignment = UIStackViewAlignmentTop;
        bottom.spacing = 40;
        [bottom addArrangedSubview:self.upstreamWirelessCard];
        [bottom addArrangedSubview:right];
        [self.upstreamWirelessCard.widthAnchor
            constraintEqualToAnchor:right.widthAnchor multiplier:1.6].active = YES;
        [root addArrangedSubview:bottom];
    } else {
        [right insertArrangedSubview:branding atIndex:0];
        [root addArrangedSubview:hero];
        [root addArrangedSubview:self.upstreamWirelessCard];
        [root addArrangedSubview:right];
    }
}

- (void)layoutUpstreamHomeReal {
    [self.setupOverlay setNeedsLayout];
    [self.setupOverlay layoutIfNeeded];
}

- (void)showUpstreamConnectionSetupFrom:(UIViewController *)presenter {
    UIStackView *root = nil;
    UIViewController *page = [self upstreamPageControllerWithBack:@"Back" root:&root];
    [root addArrangedSubview:[self upstreamLabel:@"Connection setup"
                                            size:34
                                           color:[self upstreamTextColor]
                                            bold:YES]];
    [root addArrangedSubview:[self upstreamLabel:
        @"Set up once. Your details stay saved for the next drive. Changes apply to your next connection."
                                            size:17
                                           color:[self upstreamMutedColor]
                                            bold:NO]];

    UIStackView *chooseStack = nil;
    UIView *choose = [self upstreamSectionWithTitle:@"1 · Choose your connection"
                                             symbol:@"cable.connector.horizontal"
                                              stack:&chooseStack];
    __weak UIViewController *weakPage = page;
    [chooseStack addArrangedSubview:[self upstreamButtonWithTitle:@"CarPlay on this iPhone (A → A)"
                                                          primary:YES action:^{
        self.sideStoreMode = 0;
        [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"iPlayLastMode"];
    }]];
    [chooseStack addArrangedSubview:[self upstreamButtonWithTitle:@"Receive from another iPhone (A → B)"
                                                          primary:NO action:^{
        self.sideStoreMode = 1;
        [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:@"iPlayLastMode"];
    }]];
    [chooseStack addArrangedSubview:[self upstreamButtonWithTitle:@"Connect this iPhone to another iPlay (A → B)"
                                                          primary:NO action:^{
        [weakPage dismissViewControllerAnimated:YES completion:^{
            [self showSideStoreModePicker];
        }];
    }]];
    [root addArrangedSubview:choose];

    UIStackView *pairStack = nil;
    UIView *pair = [self upstreamSectionWithTitle:@"2 · Pair your iPhone"
                                           symbol:@"iphone.and.arrow.forward"
                                            stack:&pairStack];
    [pairStack addArrangedSubview:[self upstreamLabel:
        @"Keep Bluetooth and Wi‑Fi on. For A → A, keep LocalDevVPN enabled and approve iPlay in Developer Mode on first pairing."
                                            size:16
                                           color:[self upstreamMutedColor]
                                            bold:NO]];
    [pairStack addArrangedSubview:[self upstreamButtonWithTitle:@"Choose connection mode"
                                                        primary:NO action:^{
        [weakPage dismissViewControllerAnimated:YES completion:^{
            [self showSideStoreModePicker];
        }];
    }]];
    [pairStack addArrangedSubview:[self upstreamButtonWithTitle:@"Review app permissions"
                                                        primary:NO action:^{
        NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }]];
    [root addArrangedSubview:pair];

    UIStackView *connectStack = nil;
    UIView *connect = [self upstreamSectionWithTitle:@"3 · Connect"
                                              symbol:@"play.circle"
                                               stack:&connectStack];
    [connectStack addArrangedSubview:[self upstreamLabel:
        @"Return to iPlay, then connect. Accept the CarPlay or pairing prompts shown by iOS."
                                            size:16
                                           color:[self upstreamMutedColor]
                                            bold:NO]];
    [connectStack addArrangedSubview:[self upstreamButtonWithTitle:@"Connect phone"
                                                           primary:YES action:^{
        [weakPage dismissViewControllerAnimated:YES completion:^{
            [self attemptStart];
        }];
    }]];
    [root addArrangedSubview:connect];

    UIStackView *cableStack = nil;
    UIView *cable = [self upstreamSectionWithTitle:@"Prefer a cable?"
                                            symbol:@"cable.connector"
                                             stack:&cableStack];
    [cableStack addArrangedSubview:[self upstreamLabel:
        @"On the same iPhone, iPlay uses the wired iAP2 CarKit profile through the trusted LocalDevVPN/RSD tunnel instead of a physical USB cable."
                                            size:16
                                           color:[self upstreamMutedColor]
                                            bold:NO]];
    [cableStack addArrangedSubview:[self upstreamButtonWithTitle:@"Use local wired iAP2"
                                                         primary:NO action:^{
        self.sideStoreMode = 0;
        [weakPage dismissViewControllerAnimated:YES completion:^{
            [self attemptStart];
        }];
    }]];
    [root addArrangedSubview:cable];

    [presenter presentViewController:page animated:YES completion:nil];
}

- (void)showUpstreamAboutPageFrom:(UIViewController *)presenter {
    UIStackView *root = nil;
    UIViewController *page = [self upstreamPageControllerWithBack:@"Back" root:&root];
    [root addArrangedSubview:[self upstreamLabel:@"iPlay"
                                            size:40
                                           color:[self upstreamTextColor]
                                            bold:YES]];
    [root addArrangedSubview:[self upstreamLabel:@"CarPlay, right here on your iPhone."
                                            size:20
                                           color:[self upstreamMutedColor]
                                            bold:NO]];

    UIStackView *previewStack = nil;
    UIView *preview = [self upstreamSectionWithTitle:@"Public preview · 0.1"
                                              symbol:@"car"
                                               stack:&previewStack];
    [previewStack addArrangedSubview:[self upstreamLabel:
        @"An independent CarPlay receiver port for iOS and SideStore. A → A uses LocalDevVPN and trusted Remote Pairing/RSD; A → B uses the same receiver engine over a second iPhone."
                                            size:17
                                           color:[self upstreamTextColor]
                                            bold:NO]];
    [root addArrangedSubview:preview];

    UIStackView *ossStack = nil;
    UIView *oss = [self upstreamSectionWithTitle:@"Made possible by open source"
                                          symbol:@"chevron.left.forwardslash.chevron.right"
                                           stack:&ossStack];
    [ossStack addArrangedSubview:[self upstreamLabel:
        @"Receiver based on xcertplay/DiPlay and Showcase. DiPlay’s interface follows DiAuto’s design. Preserve the GPL-3.0 / AGPL-3.0 source and license obligations when redistributing this build.\n\nCarPlay and the CarPlay icon belong to Apple Inc. iPlay is an independent project."
                                            size:16
                                           color:[self upstreamMutedColor]
                                            bold:NO]];
    [root addArrangedSubview:oss];

    [presenter presentViewController:page animated:YES completion:nil];
}

- (void)showUpstreamSettingsReal {
    UIStackView *root = nil;
    UIViewController *settings = [self upstreamPageControllerWithBack:@"Back" root:&root];

    [root addArrangedSubview:[self upstreamLabel:@"Your drive, your way."
                                            size:34
                                           color:[self upstreamTextColor]
                                            bold:YES]];
    [root addArrangedSubview:[self upstreamLabel:
        @"Display, audio and location changes apply to your next CarPlay connection."
                                            size:17
                                           color:[self upstreamMutedColor]
                                            bold:NO]];

    UIStackView *connectionStack = nil;
    UIView *connection = [self upstreamSectionWithTitle:@"Connection setup"
                                                 symbol:@"cable.connector.horizontal"
                                                  stack:&connectionStack];
    [connectionStack addArrangedSubview:[self upstreamLabel:
        @"Choose how to connect, follow the setup steps and save the mode you want to use."
                                            size:16
                                           color:[self upstreamMutedColor]
                                            bold:NO]];
    __weak UIViewController *weakSettings = settings;
    [connectionStack addArrangedSubview:[self upstreamButtonWithTitle:@"Open connection setup"
                                                              primary:NO action:^{
        [self showUpstreamConnectionSetupFrom:weakSettings];
    }]];
    [root addArrangedSubview:connection];

    UIStackView *diagnosticsStack = nil;
    UIView *diagnostics = [self upstreamSectionWithTitle:@"Diagnostics"
                                                  symbol:@"stethoscope"
                                                   stack:&diagnosticsStack];
    [diagnosticsStack addArrangedSubview:[self upstreamButtonWithTitle:@"Save diagnostic report"
                                                               primary:NO action:^{
        [self exportDiagnostics];
    }]];
    [diagnosticsStack addArrangedSubview:[self upstreamLabel:
        @"Reports are created locally and the iOS share sheet lets you choose Files or another destination. Nothing is sent automatically."
                                            size:14
                                           color:[self upstreamMutedColor]
                                            bold:NO]];
    [root addArrangedSubview:diagnostics];

    UIStackView *automaticStack = nil;
    UIView *automatic = [self upstreamSectionWithTitle:@"Automatic connection"
                                                symbol:@"bolt.horizontal.circle"
                                                 stack:&automaticStack];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [self upstreamAddToggleTo:automaticStack
                        title:@"Connect when iPlay opens"
                  description:@"Use your last connection mode automatically."
                        value:[defaults boolForKey:@"iPlayAutoConnect"]
                      changed:^(BOOL value) {
        [defaults setBool:value forKey:@"iPlayAutoConnect"];
    }];
    [self upstreamAddToggleTo:automaticStack
                        title:@"Reconnect when iPlay returns"
                  description:@"If CarPlay has stopped, returning to iPlay starts the saved connection mode."
                        value:[defaults boolForKey:@"iPlayAutoForeground"]
                      changed:^(BOOL value) {
        [defaults setBool:value forKey:@"iPlayAutoForeground"];
    }];
    [root addArrangedSubview:automatic];

    UIStackView *displayStack = nil;
    UIView *display = [self upstreamSectionWithTitle:@"Display and performance"
                                              symbol:@"display"
                                               stack:&displayStack];
    [self upstreamAddChoiceTo:displayStack
                        title:@"Physical length"
                      options:@[@"100 mm", @"150 mm", @"200 mm", @"250 mm", @"300 mm", @"350 mm", @"400 mm"]
                       values:@[@100, @150, @200, @250, @300, @350, @400]
                   currentKey:@"iPlayPhysicalWidthMm"
                 defaultValue:200
                   reconnects:NO];
    [displayStack addArrangedSubview:[self upstreamLabel:
        @"Changes the size of CarPlay icons and text by changing the physical display width reported to the iPhone."
                                            size:14
                                           color:[self upstreamMutedColor]
                                            bold:NO]];

    [self upstreamAddChoiceTo:displayStack
                        title:@"Resolution"
                      options:@[@"0.3x", @"0.4x", @"0.5x", @"0.6x", @"0.7x", @"0.8x", @"0.9x", @"1.0x"]
                       values:@[@3, @4, @5, @6, @7, @8, @9, @10]
                   currentKey:@"iPlayDisplayScaleTenths"
                 defaultValue:10
                   reconnects:NO];

    [self upstreamAddChoiceTo:displayStack
                        title:@"Music buffer"
                      options:@[@"300 ms · default", @"500 ms", @"1000 ms · most stable"]
                       values:@[@300, @500, @1000]
                   currentKey:@"iPlayMusicBufferMs"
                 defaultValue:300
                   reconnects:NO];

    [self upstreamAddChoiceTo:displayStack
                        title:@"Frame rate"
                      options:@[@"30 fps", @"35 fps", @"40 fps", @"45 fps", @"50 fps", @"55 fps", @"60 fps"]
                       values:@[@30, @35, @40, @45, @50, @55, @60]
                   currentKey:@"iPlayFrameRate"
                 defaultValue:60
                   reconnects:NO];

    [self upstreamAddToggleTo:displayStack
                        title:@"Efficient video"
                  description:@"Use HEVC. Leave off for the widest receiver compatibility."
                        value:[defaults boolForKey:@"iPlayHEVC"]
                      changed:^(BOOL value) {
        [defaults setBool:value forKey:@"iPlayHEVC"];
    }];

    [self upstreamAddToggleTo:displayStack
                        title:@"Right-hand drive"
                  description:@"Place CarPlay’s controls closer to the driver."
                        value:[defaults boolForKey:@"iPlayRightHandDrive"]
                      changed:^(BOOL value) {
        [defaults setBool:value forKey:@"iPlayRightHandDrive"];
    }];

    if ([defaults objectForKey:@"iPlayFullScreen"] == nil)
        [defaults setBool:YES forKey:@"iPlayFullScreen"];
    [self upstreamAddToggleTo:displayStack
                        title:@"Full screen"
                  description:@"Hide iPlay’s own chrome while CarPlay is open."
                        value:[defaults boolForKey:@"iPlayFullScreen"]
                      changed:^(BOOL value) {
        [defaults setBool:value forKey:@"iPlayFullScreen"];
    }];
    [root addArrangedSubview:display];

    UIStackView *audioStack = nil;
    UIView *audio = [self upstreamSectionWithTitle:@"Audio routing"
                                            symbol:@"speaker.wave.2"
                                             stack:&audioStack];
    BOOL focus = [defaults objectForKey:@"iPlayAudioFocus"] == nil
        ? YES : [defaults boolForKey:@"iPlayAudioFocus"];
    [self upstreamAddToggleTo:audioStack
                        title:@"Audio focus"
                  description:@"Let CarPlay audio take primary playback focus instead of mixing with other iPhone audio."
                        value:focus
                      changed:^(BOOL value) {
        [defaults setBool:value forKey:@"iPlayAudioFocus"];
    }];
    [root addArrangedSubview:audio];

    UIStackView *locationStack = nil;
    UIView *location = [self upstreamSectionWithTitle:@"Location"
                                               symbol:@"location"
                                                stack:&locationStack];
    [self upstreamAddToggleTo:locationStack
                        title:@"Report location to iPhone"
                  description:@"A → A only. Advertise iAP2 LocationInformation and send this iPhone’s live GPS fix while CarPlay requests it."
                        value:[defaults boolForKey:@"iPlayLocationReport"]
                      changed:^(BOOL value) {
        [defaults setBool:value forKey:@"iPlayLocationReport"];
    }];
    [root addArrangedSubview:location];

    UIStackView *permissionsStack = nil;
    UIView *permissions = [self upstreamSectionWithTitle:@"Permissions and connection help"
                                                  symbol:@"lock.shield"
                                                   stack:&permissionsStack];
    [permissionsStack addArrangedSubview:[self upstreamLabel:
        @"Local network access is used by the receiver. Bluetooth is used for two-iPhone wireless bootstrap; A → A relies on LocalDevVPN and trusted Remote Pairing."
                                            size:16
                                           color:[self upstreamMutedColor]
                                            bold:NO]];
    [permissionsStack addArrangedSubview:[self upstreamButtonWithTitle:@"App permissions"
                                                               primary:NO action:^{
        NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }]];
    [permissionsStack addArrangedSubview:[self upstreamButtonWithTitle:@"Bluetooth settings"
                                                               primary:NO action:^{
        NSURL *url = [NSURL URLWithString:@"App-Prefs:root=Bluetooth"];
        if (![UIApplication.sharedApplication canOpenURL:url])
            url = [NSURL URLWithString:@"prefs:root=Bluetooth"];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }]];
    [permissionsStack addArrangedSubview:[self upstreamButtonWithTitle:@"Wireless connection help"
                                                               primary:NO action:^{
        UIAlertController *help =
            [UIAlertController alertControllerWithTitle:@"Wireless connection help"
                                                message:@"A → A: enable LocalDevVPN, then Connect phone. First run may require Remote Pairing approval.\n\nA → B: keep Wi‑Fi and Bluetooth enabled on both iPhones and choose the matching mode in Connection setup."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [help addAction:[UIAlertAction actionWithTitle:@"OK"
                                                style:UIAlertActionStyleCancel
                                              handler:nil]];
        [[self topPresenter] presentViewController:help animated:YES completion:nil];
    }]];
    [root addArrangedSubview:permissions];

    UIStackView *aboutStack = nil;
    UIView *about = [self upstreamSectionWithTitle:@"About"
                                            symbol:@"info.circle"
                                             stack:&aboutStack];
    [aboutStack addArrangedSubview:[self upstreamButtonWithTitle:@"About iPlay"
                                                         primary:NO action:^{
        [self showUpstreamAboutPageFrom:weakSettings];
    }]];
    [root addArrangedSubview:about];

    [self.vc presentViewController:settings animated:YES completion:nil];
}
