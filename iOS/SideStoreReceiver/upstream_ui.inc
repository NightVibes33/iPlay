
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

- (void)upstreamApplyLetterSpacing:(CGFloat)em toLabel:(UILabel *)label {
    if (!label.text.length || !label.font) return;
    CGFloat kern = label.font.pointSize * em;
    label.attributedText = [[NSAttributedString alloc]
        initWithString:label.text
            attributes:@{
                NSKernAttributeName: @(kern),
                NSFontAttributeName: label.font,
                NSForegroundColorAttributeName: label.textColor ?: [UIColor whiteColor],
            }];
}

- (UIButton *)upstreamButtonWithTitle:(NSString *)title
                              primary:(BOOL)primary
                               height:(CGFloat)height
                               action:(void (^)(void))action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    [self styleUpstreamButton:button primary:primary];
    [button.heightAnchor constraintEqualToConstant:height].active = YES;
    if (action) {
        [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *sender) {
            (void)sender;
            action();
        }] forControlEvents:UIControlEventTouchUpInside];
    }
    return button;
}

- (UIButton *)upstreamButtonWithTitle:(NSString *)title
                              primary:(BOOL)primary
                               action:(void (^)(void))action {
    return [self upstreamButtonWithTitle:title
                                 primary:primary
                                  height:60
                                  action:action];
}

- (UIStackView *)upstreamVerticalStack:(CGFloat)spacing {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFill;
    stack.spacing = spacing;
    return stack;
}

- (UIView *)upstreamSpacer:(CGFloat)height {
    UIView *spacer = [[UIView alloc] init];
    [spacer.heightAnchor constraintEqualToConstant:height].active = YES;
    return spacer;
}

- (UIView *)upstreamPlainCardWithStack:(UIStackView **)outStack {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [self upstreamSurfaceColor];
    card.layer.cornerRadius = 20;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [self upstreamBorderColor].CGColor;

    UIStackView *content = [self upstreamVerticalStack:0];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [content.topAnchor constraintEqualToAnchor:card.topAnchor constant:24],
        [content.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-24],
    ]];
    if (outStack) *outStack = content;
    return card;
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
    UIButton *home = [self upstreamButtonWithTitle:@"Car home"
                                                  primary:NO
                                                   height:56
                                                   action:^{
        [self upstreamHomeTapped];
    }];
    home.tag = 0x4450484d;
    [home.widthAnchor constraintEqualToConstant:130].active = YES;
    [header addArrangedSubview:home];
    [root addArrangedSubview:header];

    BOOL wide = [self rootContentView].bounds.size.width >= 850.0;

    UIStackView *hero = [self upstreamVerticalStack:10];
    self.upstreamEyebrowLabel =
        [self upstreamLabel:@"YOUR PHONE. YOUR DRIVE."
                       size:12 color:[self upstreamAccentColor] bold:YES];
    self.upstreamEyebrowLabel.accessibilityLabel = @"Your phone. Your drive.";
    [self upstreamApplyLetterSpacing:0.16 toLabel:self.upstreamEyebrowLabel];
    self.upstreamHeroTitleLabel =
        [self upstreamLabel:@"A familiar drive."
                       size:(wide ? 42 : 36)
                      color:[self upstreamTextColor] bold:YES];
    self.upstreamHeroBodyLabel =
        [self upstreamLabel:@"Your maps, music and conversations.\nCarPlay, right here on your display."
                       size:19 color:[self upstreamMutedColor] bold:NO];
    [hero addArrangedSubview:self.upstreamEyebrowLabel];
    [hero setCustomSpacing:12 afterView:self.upstreamEyebrowLabel];
    [hero addArrangedSubview:self.upstreamHeroTitleLabel];
    [hero setCustomSpacing:10 afterView:self.upstreamHeroTitleLabel];
    [hero addArrangedSubview:self.upstreamHeroBodyLabel];

    UIStackView *cardStack = nil;
    self.upstreamWirelessCard = [self upstreamPlainCardWithStack:&cardStack];
    self.upstreamWirelessLabel =
        [self upstreamLabel:@"WIRELESS CARPLAY"
                       size:12 color:[self upstreamAccentColor] bold:YES];
    [self upstreamApplyLetterSpacing:0.12 toLabel:self.upstreamWirelessLabel];
    [cardStack addArrangedSubview:self.upstreamWirelessLabel];
    [cardStack setCustomSpacing:10 afterView:self.upstreamWirelessLabel];

    self.headlineLabel =
        [self upstreamLabel:@"Ready when you are"
                       size:24 color:[self upstreamTextColor] bold:YES];
    [cardStack addArrangedSubview:self.headlineLabel];
    [cardStack setCustomSpacing:16 afterView:self.headlineLabel];

    self.primaryButton = [self upstreamButtonWithTitle:@"Connect phone"
                                              primary:YES
                                               height:68
                                               action:^{ [self primaryTapped]; }];
    [cardStack addArrangedSubview:self.primaryButton];
    [cardStack setCustomSpacing:14 afterView:self.primaryButton];

    self.subtitleLabel =
        [self upstreamLabel:@"Keep LocalDevVPN enabled. iPlay pairs with this iPhone through Developer Mode."
                       size:15 color:[self upstreamMutedColor] bold:NO];
    [cardStack addArrangedSubview:self.subtitleLabel];
    [cardStack setCustomSpacing:16 afterView:self.subtitleLabel];

    self.secondaryButton = [self upstreamButtonWithTitle:@"Choose iPhone"
                                                primary:NO
                                                 height:56
                                                 action:^{ [self secondaryTapped]; }];
    [cardStack addArrangedSubview:self.secondaryButton];

    self.carHintLabel =
        [self upstreamLabel:@""
                       size:14 color:[self upstreamMutedColor] bold:NO];
    self.carHintLabel.hidden = YES;
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
                                                height:68
                                                action:^{ [self receiverTapped]; }];
    [right addArrangedSubview:self.receiverButton];
    self.upstreamReceiverHintLabel =
        [self upstreamLabel:@"Use this iPhone as the CarPlay display for another iPhone."
                       size:14 color:[self upstreamMutedColor] bold:NO];
    self.upstreamReceiverHintLabel.textAlignment = NSTextAlignmentCenter;
    [right addArrangedSubview:self.upstreamReceiverHintLabel];
    [right setCustomSpacing:24 afterView:self.upstreamReceiverHintLabel];

    self.tertiaryButton = [self upstreamButtonWithTitle:@"Settings"
                                               primary:NO
                                                height:68
                                                action:^{ [self tertiaryTapped]; }];
    [right addArrangedSubview:self.tertiaryButton];
    self.upstreamSettingsHintLabel =
        [self upstreamLabel:@"Make iPlay feel right for this display."
                       size:14 color:[self upstreamMutedColor] bold:NO];
    self.upstreamSettingsHintLabel.textAlignment = NSTextAlignmentCenter;
    [right addArrangedSubview:self.upstreamSettingsHintLabel];
    [right setCustomSpacing:24 afterView:self.upstreamSettingsHintLabel];

    self.upstreamPreviewLabel =
        [self upstreamLabel:[NSString stringWithFormat:@"PUBLIC PREVIEW  ·  %s", APP_VERSION]
                       size:12 color:[self upstreamMutedColor] bold:NO];
    [self upstreamApplyLetterSpacing:0.08 toLabel:self.upstreamPreviewLabel];
    self.upstreamPreviewLabel.textAlignment = NSTextAlignmentCenter;
    [right addArrangedSubview:self.upstreamPreviewLabel];

    UIStackView *body = [self upstreamVerticalStack:0];
    if (wide) {
        UIStackView *top = [[UIStackView alloc] init];
        top.axis = UILayoutConstraintAxisHorizontal;
        top.alignment = UIStackViewAlignmentTop;
        top.spacing = 40;
        [top addArrangedSubview:hero];
        [top addArrangedSubview:branding];
        [hero.widthAnchor constraintEqualToAnchor:branding.widthAnchor multiplier:1.6].active = YES;
        [body addArrangedSubview:top];
        [body addArrangedSubview:[self upstreamSpacer:26]];

        UIStackView *bottom = [[UIStackView alloc] init];
        bottom.axis = UILayoutConstraintAxisHorizontal;
        bottom.alignment = UIStackViewAlignmentTop;
        bottom.spacing = 40;
        [bottom addArrangedSubview:self.upstreamWirelessCard];
        [bottom addArrangedSubview:right];
        [self.upstreamWirelessCard.widthAnchor
            constraintEqualToAnchor:right.widthAnchor multiplier:1.6].active = YES;
        [body addArrangedSubview:bottom];
    } else {
        [body addArrangedSubview:hero];
        [body addArrangedSubview:[self upstreamSpacer:26]];
        [body addArrangedSubview:self.upstreamWirelessCard];
        [body addArrangedSubview:[self upstreamSpacer:26]];
        [body addArrangedSubview:branding];
        [body addArrangedSubview:[self upstreamSpacer:24]];
        [body addArrangedSubview:right];
    }
    [root addArrangedSubview:body];
}

- (void)layoutUpstreamHomeReal {
    [self.setupOverlay setNeedsLayout];
    [self.setupOverlay layoutIfNeeded];
}

